use std::collections::VecDeque;
use std::io::{self, ErrorKind};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::time::{Duration, Instant};

use boringtun::noise::{Tunn, TunnResult};
use boringtun::x25519::{PublicKey, StaticSecret};
use tokio::net::UdpSocket;
use tokio::task::JoinHandle;
use zeroize::Zeroizing;

use crate::stack::{Network, random};

const DATAGRAM_BUFFER: usize = 65_536;
const QUEUE_LIMIT: usize = 256;
const TIMER_INTERVAL: Duration = Duration::from_millis(100);

pub(crate) struct Keys {
    pub private: Zeroizing<[u8; 32]>,
    pub peer: [u8; 32],
    pub preshared: Option<Zeroizing<[u8; 32]>>,
}

pub(crate) struct Tunnel {
    pub network: Network,
    job: Option<JoinHandle<()>>,
}

impl Tunnel {
    pub(crate) async fn start(
        address: IpAddr,
        mtu: usize,
        endpoint: SocketAddr,
        keys: Keys,
    ) -> io::Result<Self> {
        let private_key = StaticSecret::from(*keys.private);
        let peer_key = PublicKey::from(keys.peer);
        if !private_key.diffie_hellman(&peer_key).was_contributory() {
            return Err(io::Error::new(
                ErrorKind::InvalidInput,
                "invalid WireGuard peer key",
            ));
        }
        let any = if endpoint.is_ipv6() {
            IpAddr::V6(Ipv6Addr::UNSPECIFIED)
        } else {
            IpAddr::V4(Ipv4Addr::UNSPECIFIED)
        };
        let udp = UdpSocket::bind(SocketAddr::new(any, 0)).await?;
        let network = Network::new(address, mtu)?;
        let engine = Engine {
            network: network.clone(),
            tunn: Tunn::new(
                private_key,
                peer_key,
                keys.preshared.as_ref().map(|value| **value),
                None,
                u32::from_ne_bytes(random()?) & 0x00ff_ffff,
                None,
            ),
            endpoint,
            outbound: VecDeque::new(),
            scratch: vec![0; DATAGRAM_BUFFER],
        };
        let job = tokio::spawn(async move { engine.run(udp).await });
        Ok(Self {
            network,
            job: Some(job),
        })
    }

    pub(crate) async fn shutdown(mut self) {
        if let Some(job) = self.job.take() {
            job.abort();
            let _ = job.await;
        }
    }
}

impl Drop for Tunnel {
    fn drop(&mut self) {
        if let Some(job) = self.job.take() {
            job.abort();
        }
        self.network.stop();
    }
}

struct Engine {
    network: Network,
    tunn: Tunn,
    endpoint: SocketAddr,
    outbound: VecDeque<(Vec<u8>, SocketAddr)>,
    scratch: Vec<u8>,
}

struct NetworkGuard(Network);

impl Drop for NetworkGuard {
    fn drop(&mut self) {
        self.0.stop();
    }
}

fn enqueue(queue: &mut VecDeque<(Vec<u8>, SocketAddr)>, bytes: &[u8], target: SocketAddr) {
    if queue.len() < QUEUE_LIMIT {
        queue.push_back((bytes.to_vec(), target));
    }
}

impl Engine {
    async fn run(mut self, udp: UdpSocket) {
        let _scope = NetworkGuard(self.network.clone());
        let mut input = vec![0; DATAGRAM_BUFFER];
        let mut timer_at = Instant::now();
        loop {
            let (packets, delay) = self.network.poll();
            for packet in packets {
                if let TunnResult::WriteToNetwork(data) =
                    self.tunn.encapsulate(&packet, &mut self.scratch)
                {
                    enqueue(&mut self.outbound, data, self.endpoint);
                }
            }
            if timer_at <= Instant::now() {
                timer_at = Instant::now() + TIMER_INTERVAL;
                if let TunnResult::WriteToNetwork(data) = self.tunn.update_timers(&mut self.scratch)
                {
                    enqueue(&mut self.outbound, data, self.endpoint);
                }
            }
            let sleep = delay.min(timer_at.saturating_duration_since(Instant::now()));
            tokio::select! {
                packet = udp.recv_from(&mut input) => match packet {
                    Ok((size, source)) => self.receive(source, &input[..size]),
                    // Brief asynchronous socket errors can occur when the peer or
                    // the route is temporarily unavailable. Keep the tunnel alive.
                    Err(_) => tokio::time::sleep(Duration::from_millis(50)).await,
                },
                ready = udp.writable(), if !self.outbound.is_empty() => {
                    if ready.is_err() {
                        return;
                    }
                    while let Some((bytes, target)) = self.outbound.front() {
                        match udp.try_send_to(bytes, *target) {
                            Err(err) if err.kind() == ErrorKind::WouldBlock => break,
                            _ => { self.outbound.pop_front(); }
                        }
                    }
                },
                _ = tokio::time::sleep(sleep) => {}
                _ = self.network.wake_requested() => {}
            }
        }
    }

    fn receive(&mut self, source: SocketAddr, packet: &[u8]) {
        if packet.is_empty() {
            return;
        }
        match self
            .tunn
            .decapsulate(Some(source.ip()), packet, &mut self.scratch)
        {
            TunnResult::WriteToNetwork(output) => {
                // A handshake response or confirmation authenticates the peer.
                // A rate-limit cookie authenticates neither the sender nor its endpoint.
                let authenticated = matches!(
                    (packet.get(..4), output.get(..4)),
                    (Some([1, 0, 0, 0]), Some([2, 0, 0, 0]))
                        | (Some([2, 0, 0, 0]), Some([4, 0, 0, 0]))
                );
                enqueue(&mut self.outbound, output, source);
                if authenticated {
                    self.endpoint = source;
                    self.drain_tunnel(source);
                }
            }
            TunnResult::WriteToTunnelV4(output, _) | TunnResult::WriteToTunnelV6(output, _) => {
                self.endpoint = source;
                self.network.receive(output);
            }
            TunnResult::Done if packet.starts_with(&[4, 0, 0, 0]) => {
                // An authenticated keepalive can also update the peer endpoint.
                self.endpoint = source;
            }
            TunnResult::Done | TunnResult::Err(_) => {}
        }
    }

    fn drain_tunnel(&mut self, endpoint: SocketAddr) {
        for _ in 0..QUEUE_LIMIT {
            let TunnResult::WriteToNetwork(output) =
                self.tunn.decapsulate(None, &[], &mut self.scratch)
            else {
                break;
            };
            enqueue(&mut self.outbound, output, endpoint);
        }
    }
}
