use std::collections::BTreeMap;
use std::time::{Duration, Instant};

const HEADER_LEN: usize = 40;
const FRAGMENT_HEADER_LEN: usize = 8;
const MAX_DATAGRAMS: usize = 16;
const REASSEMBLY_TIMEOUT: Duration = Duration::from_secs(60);

/// smoltcp reassembles IPv4, but does not reassemble ordinary IPv6 packets
/// on an IP-medium interface. Reassemble them before handing them to it.
#[derive(Default)]
pub(crate) struct Ipv6Fragments {
    entries: Vec<Datagram>,
}

#[derive(PartialEq, Eq)]
struct Key {
    addresses: [u8; 32],
    identification: [u8; 4],
}

struct Fragment<'a> {
    key: Key,
    prefix: &'a [u8],
    previous_header: usize,
    protocol: u8,
    offset: usize,
    more: bool,
    bytes: &'a [u8],
}

impl<'a> Fragment<'a> {
    fn parse(packet: &'a [u8]) -> Result<Option<Self>, ()> {
        if !packet.first().is_some_and(|byte| byte >> 4 == 6) {
            return Ok(None);
        }
        let header = packet.get(..HEADER_LEN).ok_or(())?;
        let payload_len = usize::from(u16::from_be_bytes([header[4], header[5]]));
        if packet.len() != HEADER_LEN + payload_len {
            return Err(());
        }

        let mut previous_header = 6;
        let mut protocol = header[6];
        let mut cursor = HEADER_LEN;
        while matches!(protocol, 0 | 43 | 60) {
            // Hop-by-Hop, Routing, and Destination Options share this layout.
            let extension = packet.get(cursor..cursor + 2).ok_or(())?;
            previous_header = cursor;
            protocol = extension[0];
            cursor += (usize::from(extension[1]) + 1) * 8;
        }
        if protocol != 44 {
            return Ok(None);
        }

        let fragment = packet.get(cursor..cursor + FRAGMENT_HEADER_LEN).ok_or(())?;
        let offset_and_flags = u16::from_be_bytes([fragment[2], fragment[3]]);
        let offset = usize::from(offset_and_flags & 0xfff8);
        let more = offset_and_flags & 1 != 0;
        let bytes = &packet[cursor + FRAGMENT_HEADER_LEN..];
        if offset + bytes.len() > usize::from(u16::MAX)
            || (more && (bytes.is_empty() || !bytes.len().is_multiple_of(8)))
            || (offset != 0 && bytes.is_empty())
        {
            return Err(());
        }

        Ok(Some(Self {
            key: Key {
                addresses: header[8..40].try_into().map_err(|_| ())?,
                identification: fragment[4..8].try_into().map_err(|_| ())?,
            },
            prefix: &packet[..cursor],
            previous_header,
            protocol: fragment[0],
            offset,
            more,
            bytes,
        }))
    }

    fn prefix(&self) -> Vec<u8> {
        let mut prefix = self.prefix.to_vec();
        prefix[self.previous_header] = self.protocol;
        prefix
    }
}

struct Datagram {
    key: Key,
    prefix: Option<Vec<u8>>,
    pieces: BTreeMap<usize, Vec<u8>>,
    received: usize,
    total: Option<usize>,
    expires: Instant,
    discarded: bool,
}

impl Datagram {
    fn add(&mut self, fragment: Fragment<'_>) -> Result<(), ()> {
        let start = fragment.offset;
        let end = start + fragment.bytes.len();
        if self
            .total
            .is_some_and(|total| end > total || (fragment.more && end == total))
        {
            return Err(());
        }
        if !fragment.more {
            if self.total.is_some_and(|total| total != end)
                || self
                    .pieces
                    .last_key_value()
                    .is_some_and(|(offset, bytes)| offset + bytes.len() > end)
            {
                return Err(());
            }
            self.total = Some(end);
        }
        if self
            .pieces
            .range(..start)
            .next_back()
            .is_some_and(|(offset, bytes)| offset + bytes.len() > start)
            || self
                .pieces
                .range(start..)
                .next()
                .is_some_and(|(offset, _)| *offset < end)
        {
            return Err(());
        }
        if start == 0 {
            self.prefix = Some(fragment.prefix());
        }
        self.received += fragment.bytes.len();
        self.pieces.insert(start, fragment.bytes.to_vec());
        Ok(())
    }

    fn assemble(self) -> Option<Vec<u8>> {
        let mut packet = self.prefix?;
        packet.reserve(self.received);
        for bytes in self.pieces.into_values() {
            packet.extend_from_slice(&bytes);
        }
        set_payload_len(packet)
    }
}

fn set_payload_len(mut packet: Vec<u8>) -> Option<Vec<u8>> {
    let len = u16::try_from(packet.len() - HEADER_LEN).ok()?;
    packet[4..6].copy_from_slice(&len.to_be_bytes());
    Some(packet)
}

impl Ipv6Fragments {
    pub(crate) fn receive(&mut self, packet: &[u8], now: Instant) -> Option<Vec<u8>> {
        let Some(fragment) = Fragment::parse(packet).ok()? else {
            return Some(packet.to_vec());
        };
        // Atomic fragments bypass the cache, even if their ID matches an
        // incomplete datagram from the same peer.
        if fragment.offset == 0 && !fragment.more {
            let mut packet = fragment.prefix();
            packet.extend_from_slice(fragment.bytes);
            return set_payload_len(packet);
        }

        self.entries.retain(|entry| now < entry.expires);
        let index = if let Some(index) = self
            .entries
            .iter()
            .position(|entry| entry.key == fragment.key)
        {
            index
        } else {
            if self.entries.len() >= MAX_DATAGRAMS {
                return None;
            }
            let index = self.entries.len();
            self.entries.push(Datagram {
                key: Key {
                    addresses: fragment.key.addresses,
                    identification: fragment.key.identification,
                },
                prefix: None,
                pieces: BTreeMap::new(),
                received: 0,
                total: None,
                expires: now + REASSEMBLY_TIMEOUT,
                discarded: false,
            });
            index
        };
        let entry = &mut self.entries[index];
        if entry.discarded {
            return None;
        }
        if entry.add(fragment).is_err() {
            // Ignore later fragments of this datagram for the remainder of
            // its reassembly lifetime (RFC 8200, section 4.5).
            entry.pieces.clear();
            entry.prefix = None;
            entry.discarded = true;
            return None;
        }
        if entry.total == Some(entry.received) {
            return self.entries.swap_remove(index).assemble();
        }
        None
    }
}
