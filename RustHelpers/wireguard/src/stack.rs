use std::collections::{HashMap, VecDeque};
use std::future::poll_fn;
use std::io::{self, ErrorKind};
use std::net::{IpAddr, SocketAddr};
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use smoltcp::iface::{Config, Interface, SocketHandle, SocketSet};
use smoltcp::phy::{Device, DeviceCapabilities, Medium, RxToken, TxToken};
use smoltcp::socket::tcp::{self, State};
use smoltcp::time::Instant as StackInstant;
use smoltcp::wire::{HardwareAddress, IpAddress, IpCidr, IpEndpoint};
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::Notify;

use crate::ipv6_fragments::Ipv6Fragments;

pub(crate) const MAX_STREAMS: usize = 128;
const MAX_TRACKED_SOCKETS: usize = MAX_STREAMS + 256;
const SEND_STALL_TIMEOUT: Duration = Duration::from_secs(60);
const BUFFER_SIZE: usize = 65_536;
const PACKET_LIMIT: usize = 128;
const EPHEMERAL_BASE: u16 = 49_152;
const PORT_REUSE_DELAY: Duration = Duration::from_secs(10);

pub(crate) fn random<const N: usize>() -> io::Result<[u8; N]> {
    let mut bytes = [0; N];
    getrandom::fill(&mut bytes)
        .map_err(|_| io::Error::other("system randomness is unavailable"))?;
    Ok(bytes)
}

struct Packets {
    mtu: usize,
    incoming: VecDeque<Vec<u8>>,
    outgoing: VecDeque<Vec<u8>>,
}

struct Inbound(Vec<u8>);
struct Outbound<'a>(&'a mut VecDeque<Vec<u8>>);

impl RxToken for Inbound {
    fn consume<R, F: FnOnce(&[u8]) -> R>(self, f: F) -> R {
        f(&self.0)
    }
}

impl TxToken for Outbound<'_> {
    fn consume<R, F: FnOnce(&mut [u8]) -> R>(self, len: usize, f: F) -> R {
        let mut packet = vec![0; len];
        let result = f(&mut packet);
        self.0.push_back(packet);
        result
    }
}

impl Device for Packets {
    type RxToken<'a> = Inbound;
    type TxToken<'a> = Outbound<'a>;

    fn receive(&mut self, _: StackInstant) -> Option<(Inbound, Outbound<'_>)> {
        if self.outgoing.len() >= PACKET_LIMIT {
            return None;
        }
        Some((
            Inbound(self.incoming.pop_front()?),
            Outbound(&mut self.outgoing),
        ))
    }

    fn transmit(&mut self, _: StackInstant) -> Option<Outbound<'_>> {
        (self.outgoing.len() < PACKET_LIMIT).then_some(Outbound(&mut self.outgoing))
    }

    fn capabilities(&self) -> DeviceCapabilities {
        let mut caps = DeviceCapabilities::default();
        caps.medium = Medium::Ip;
        caps.max_transmission_unit = self.mtu;
        caps
    }
}

struct Slot {
    handle: SocketHandle,
    port: u16,
    retired_at: Option<Instant>,
    queued_bytes: usize,
    send_progress_at: Option<Instant>,
}

struct Stack {
    address: IpAddr,
    started: Instant,
    online: bool,
    packets: Packets,
    ipv6_fragments: Ipv6Fragments,
    interface: Interface,
    sockets: SocketSet<'static>,
    slots: Vec<Slot>,
    parked_ports: HashMap<u16, Instant>,
    next_port: u16,
}

impl Stack {
    fn clock(&self) -> StackInstant {
        StackInstant::from_millis(self.started.elapsed().as_millis() as i64)
    }

    fn add_socket(&mut self, socket: tcp::Socket<'static>, port: u16) -> SocketHandle {
        let handle = self.sockets.add(socket);
        self.slots.push(Slot {
            handle,
            port,
            retired_at: None,
            queued_bytes: 0,
            send_progress_at: None,
        });
        handle
    }

    fn available_port(&mut self, now: Instant) -> io::Result<u16> {
        for _ in EPHEMERAL_BASE..=u16::MAX {
            let candidate = self.next_port;
            self.next_port = self.next_port.checked_add(1).unwrap_or(EPHEMERAL_BASE);
            if !self.slots.iter().any(|slot| slot.port == candidate)
                && !self
                    .parked_ports
                    .get(&candidate)
                    .is_some_and(|expiry| *expiry > now)
            {
                return Ok(candidate);
            }
        }
        Err(io::Error::new(
            ErrorKind::AddrNotAvailable,
            "WireGuard source ports exhausted",
        ))
    }

    fn reserve_socket(&mut self, now: Instant) -> io::Result<()> {
        let limit = || io::Error::other("WireGuard connection limit reached");
        if self
            .slots
            .iter()
            .filter(|slot| slot.retired_at.is_none())
            .count()
            >= MAX_STREAMS
        {
            return Err(limit());
        }
        if self.slots.len() < MAX_TRACKED_SOCKETS {
            return Ok(());
        }
        // Only reclaim a fully closed or TIME-WAIT socket. Preserve sockets
        // that still have TCP data or a close handshake to finish.
        let index = self
            .slots
            .iter()
            .enumerate()
            .filter_map(|(index, slot)| {
                let retired = slot.retired_at?;
                let state = self.sockets.get::<tcp::Socket>(slot.handle).state();
                matches!(state, State::Closed | State::TimeWait).then_some((index, state, retired))
            })
            .min_by_key(|(_, state, retired)| (*state != State::Closed, *retired))
            .map(|(index, _, _)| index)
            .ok_or_else(limit)?;
        let slot = self.slots.swap_remove(index);
        if self.sockets.get::<tcp::Socket>(slot.handle).state() == State::TimeWait {
            self.parked_ports.retain(|_, expiry| *expiry > now);
            self.parked_ports.insert(slot.port, now + PORT_REUSE_DELAY);
        }
        self.sockets.remove(slot.handle);
        Ok(())
    }

    fn reap_retired(&mut self) {
        let now = Instant::now();
        self.slots.retain(|slot| {
            let Some(since) = slot.retired_at else {
                return true;
            };
            let socket = self.sockets.get::<tcp::Socket>(slot.handle);
            if socket.state() == State::Closed
                || now.duration_since(since) >= Duration::from_secs(60)
            {
                self.sockets.remove(slot.handle);
                false
            } else {
                true
            }
        });
    }

    fn check_send_progress(&mut self, now: Instant) -> Duration {
        let mut remaining = SEND_STALL_TIMEOUT;
        for slot in &mut self.slots {
            let socket = self.sockets.get_mut::<tcp::Socket>(slot.handle);
            let queued = socket.send_queue();
            let fin_pending = matches!(
                socket.state(),
                State::FinWait1 | State::Closing | State::LastAck
            );
            let pending = socket.state() != State::Closed && (queued != 0 || fin_pending);
            if !pending {
                slot.send_progress_at = None;
            } else {
                // The queue retains transmitted bytes until acknowledged. A
                // shorter queue proves progress even if the peer sends other
                // traffic while our data remains unacknowledged.
                if queued < slot.queued_bytes {
                    slot.send_progress_at = Some(now);
                }
                let since = *slot.send_progress_at.get_or_insert(now);
                let left = SEND_STALL_TIMEOUT.saturating_sub(now.duration_since(since));
                if left.is_zero() {
                    socket.abort();
                }
                remaining = remaining.min(left);
            }
            slot.queued_bytes = queued;
        }
        remaining
    }
}

#[derive(Clone)]
pub(crate) struct Network {
    shared: Arc<Shared>,
}

struct Shared {
    stack: Mutex<Stack>,
    drive: Notify,
}

impl Network {
    pub(crate) fn new(address: IpAddr, mtu: usize) -> io::Result<Self> {
        let seed = u64::from_ne_bytes(random()?);
        let mut packets = Packets {
            mtu,
            incoming: VecDeque::new(),
            outgoing: VecDeque::new(),
        };
        let mut config = Config::new(HardwareAddress::Ip);
        config.random_seed = seed;
        let mut interface = Interface::new(config, &mut packets, StackInstant::from_millis(0));
        // The WireGuard peer is the next hop for every packet. This IP-only
        // interface never emits ARP or changes the host's routing table.
        interface.update_ip_addrs(|addresses| {
            let prefix = if address.is_ipv4() { 32 } else { 128 };
            addresses
                .push(IpCidr::new(address.into(), prefix))
                .expect("one address fits");
        });
        let installed = match address {
            IpAddr::V4(ip) => interface.routes_mut().add_default_ipv4_route(ip),
            IpAddr::V6(ip) => interface.routes_mut().add_default_ipv6_route(ip),
        };
        installed.map_err(io::Error::other)?;
        let port_offset = (seed as u16) % (u16::MAX - EPHEMERAL_BASE);
        let stack = Stack {
            address,
            started: Instant::now(),
            online: true,
            packets,
            ipv6_fragments: Ipv6Fragments::default(),
            interface,
            sockets: SocketSet::new(Vec::new()),
            slots: Vec::new(),
            parked_ports: HashMap::new(),
            next_port: EPHEMERAL_BASE + port_offset,
        };
        Ok(Self {
            shared: Arc::new(Shared {
                stack: Mutex::new(stack),
                drive: Notify::new(),
            }),
        })
    }

    pub(crate) async fn wake_requested(&self) {
        self.shared.drive.notified().await;
    }

    pub(crate) fn receive(&self, packet: &[u8]) {
        let mut stack = self.shared.stack.lock().expect("network stack mutex");
        if packet.len() > stack.packets.mtu || stack.packets.incoming.len() >= PACKET_LIMIT {
            return;
        }
        // The MTU applies to each incoming packet, including each fragment.
        // A reassembled IPv6 datagram can be larger than that MTU.
        if let Some(packet) = stack.ipv6_fragments.receive(packet, Instant::now()) {
            stack.packets.incoming.push_back(packet);
        }
    }

    pub(crate) fn poll(&self) -> (VecDeque<Vec<u8>>, Duration) {
        let mut stack = self.shared.stack.lock().expect("network stack mutex");
        let now = stack.clock();
        let Stack {
            interface,
            packets,
            sockets,
            ..
        } = &mut *stack;
        interface.poll(now, packets, sockets);
        let output = std::mem::take(&mut packets.outgoing);
        stack.reap_retired();
        let send_delay = stack.check_send_progress(Instant::now());
        let Stack {
            interface, sockets, ..
        } = &mut *stack;
        let delay = interface
            .poll_delay(now, sockets)
            .map(|delay| Duration::from_millis(delay.total_millis()).max(Duration::from_millis(1)))
            .unwrap_or(Duration::from_secs(1))
            .min(send_delay.max(Duration::from_millis(1)));
        (output, delay)
    }

    pub(crate) fn stop(&self) {
        let mut stack = self.shared.stack.lock().expect("network stack mutex");
        stack.online = false;
        // Aborting a live socket wakes both halves and pending connect/accept.
        for (_, socket) in stack.sockets.iter_mut() {
            let smoltcp::socket::Socket::Tcp(socket) = socket;
            socket.abort();
        }
    }

    fn start_socket(&self, target: SocketAddr) -> io::Result<Stream> {
        let mut stack = self.shared.stack.lock().expect("network stack mutex");
        if !stack.online {
            return Err(io::Error::new(
                ErrorKind::ConnectionAborted,
                "WireGuard transport stopped",
            ));
        }
        let source = stack.address;
        if source.is_ipv4() != target.is_ipv4() {
            return Err(io::Error::new(
                ErrorKind::AddrNotAvailable,
                "destination and tunnel IP families differ",
            ));
        }
        let now = Instant::now();
        stack.reserve_socket(now)?;
        let port = stack.available_port(now)?;
        let mut socket = tcp::Socket::new(
            tcp::SocketBuffer::new(vec![0; BUFFER_SIZE]),
            tcp::SocketBuffer::new(vec![0; BUFFER_SIZE]),
        );
        socket.set_congestion_control(tcp::CongestionControl::Cubic);
        let source_address = IpEndpoint::new(IpAddress::from(source), port);
        socket
            .connect(
                stack.interface.context(),
                IpEndpoint::from(target),
                source_address,
            )
            .map_err(io::Error::other)?;
        let handle = stack.add_socket(socket, port);
        self.shared.drive.notify_one();
        Ok(Stream {
            network: self.clone(),
            handle,
            sent_eof: false,
            received_eof: false,
        })
    }

    pub(crate) async fn connect(&self, target: SocketAddr) -> io::Result<Stream> {
        let mut stream = self.start_socket(target)?;
        stream.wait_for_connection().await?;
        Ok(stream)
    }
}

pub(crate) struct Stream {
    network: Network,
    handle: SocketHandle,
    sent_eof: bool,
    received_eof: bool,
}

impl Stream {
    pub(crate) async fn wait_for_connection(&mut self) -> io::Result<()> {
        poll_fn(|context| {
            let mut stack = self
                .network
                .shared
                .stack
                .lock()
                .expect("network stack mutex");
            if !stack.online {
                return Poll::Ready(Err(io::Error::new(
                    ErrorKind::ConnectionAborted,
                    "WireGuard transport stopped",
                )));
            }
            let socket = stack.sockets.get_mut::<tcp::Socket>(self.handle);
            match socket.state() {
                State::Established | State::CloseWait => Poll::Ready(Ok(())),
                State::Closed => Poll::Ready(Err(io::Error::new(
                    ErrorKind::ConnectionRefused,
                    "destination refused the connection",
                ))),
                _ => {
                    socket.register_recv_waker(context.waker());
                    Poll::Pending
                }
            }
        })
        .await
    }
}

impl AsyncRead for Stream {
    fn poll_read(
        mut self: Pin<&mut Self>,
        context: &mut Context<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        if self.received_eof || buffer.remaining() == 0 {
            return Poll::Ready(Ok(()));
        }
        let mut stack = self
            .network
            .shared
            .stack
            .lock()
            .expect("network stack mutex");
        if !stack.online {
            return Poll::Ready(Err(io::Error::new(
                ErrorKind::ConnectionAborted,
                "WireGuard transport stopped",
            )));
        }
        let socket = stack.sockets.get_mut::<tcp::Socket>(self.handle);
        if socket.can_recv() {
            let size = socket
                .recv_slice(buffer.initialize_unfilled())
                .map_err(io::Error::other)?;
            buffer.advance(size);
            self.network.shared.drive.notify_one();
            return Poll::Ready(Ok(()));
        }
        if !socket.may_recv() {
            if socket.recv_slice(&mut []) != Err(tcp::RecvError::Finished) {
                return Poll::Ready(Err(io::Error::new(
                    ErrorKind::ConnectionReset,
                    "destination reset the connection",
                )));
            }
            drop(stack);
            self.received_eof = true;
            return Poll::Ready(Ok(()));
        }
        socket.register_recv_waker(context.waker());
        Poll::Pending
    }
}

impl AsyncWrite for Stream {
    fn poll_write(
        self: Pin<&mut Self>,
        context: &mut Context<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        if bytes.is_empty() {
            return Poll::Ready(Ok(0));
        }
        let mut stack = self
            .network
            .shared
            .stack
            .lock()
            .expect("network stack mutex");
        if !stack.online {
            return Poll::Ready(Err(io::Error::new(
                ErrorKind::ConnectionAborted,
                "WireGuard transport stopped",
            )));
        }
        let socket = stack.sockets.get_mut::<tcp::Socket>(self.handle);
        if !socket.may_send() {
            return Poll::Ready(Err(io::Error::new(
                ErrorKind::BrokenPipe,
                "destination closed the connection",
            )));
        }
        if socket.can_send() {
            let size = socket.send_slice(bytes).map_err(io::Error::other)?;
            let slot = stack
                .slots
                .iter_mut()
                .find(|slot| slot.handle == self.handle)
                .expect("stream has a socket slot");
            // Writes append to the queue; count them before the next poll can
            // observe ACKs, which may otherwise be masked by new writes.
            slot.queued_bytes += size;
            self.network.shared.drive.notify_one();
            return Poll::Ready(Ok(size));
        }
        socket.register_send_waker(context.waker());
        Poll::Pending
    }

    fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<io::Result<()>> {
        if !self.sent_eof {
            let mut stack = self
                .network
                .shared
                .stack
                .lock()
                .expect("network stack mutex");
            stack.sockets.get_mut::<tcp::Socket>(self.handle).close();
            self.network.shared.drive.notify_one();
            drop(stack);
            self.sent_eof = true;
        }
        Poll::Ready(Ok(()))
    }
}

impl Drop for Stream {
    fn drop(&mut self) {
        let mut stack = self
            .network
            .shared
            .stack
            .lock()
            .expect("network stack mutex");
        if !(self.sent_eof && self.received_eof) {
            stack.sockets.get_mut::<tcp::Socket>(self.handle).abort();
        }
        if let Some(slot) = stack
            .slots
            .iter_mut()
            .find(|slot| slot.handle == self.handle)
        {
            slot.retired_at = Some(Instant::now());
        }
        self.network.shared.drive.notify_one();
    }
}
