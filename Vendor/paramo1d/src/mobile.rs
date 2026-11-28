use crate::{
    artifacts::{self},
    Verifier,
};
use anyhow::{bail, ensure, Context, Result};
use futures::{stream::FuturesUnordered, StreamExt};
use libp2p::{
    identify, ping,
    request_response::{self as rr, Message, ProtocolSupport},
    swarm::{NetworkBehaviour, SwarmEvent},
    Multiaddr, PeerId, StreamProtocol, SwarmBuilder,
};
use noid_chain::{
    block_header::{block_id, semantic_header_id, BlockHeader},
    storage::{
        AuthenticatedSnapshotMetadata, FinalizedSnapshotStaging,
        MdbxChainContext, SnapshotSegmentDescriptor, SnapshotStagingSession,
    },
    consensus::{network::NetworkConfig, params},
    history_step::HistoryStepTerminalMetadata,
};
use noid_p2p::{
    fork_origin::{ForkOriginCodec, ForkOriginResponse},
    header_sync_codec::HeaderSyncCodec,
    history_step_codec::HistoryStepTerminalCodec,
    manifest_page_codec::ManifestPageCodec,
    mempool_sync_codec::MempoolSyncCodec,
    network_profile::{
        NetworkProfile, NetworkProfileCodec, NetworkProfileRequest, NetworkProfileResponse,
    },
    object_codec::ObjectCodec,
    object_protocol::{DataResponseStatus, GetObjectsRequest, GetObjectsResponse, ObjectId},
    protocol::{
        GetHeadersRequest, GetHeadersResponse, GetHistoryStepTerminalRequest,
        GetHistoryStepTerminalResponse, GetMempoolResponse, GetSnapshotManifestPageRequest,
        GetSnapshotManifestPageResponse, GetStateManifestHeader, GetStateManifestRequest,
        GetStateSegmentRequest, GetStateSegmentResponse, MempoolRequest,
    },
    state_manifest_codec::StateManifestCodec,
    state_segment_codec::StateSegmentCodec,
};
use std::{
    cell::RefCell,
    collections::{BTreeMap, HashMap, HashSet},
    fs::{self, File},
    io::{Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};
use tokio::sync::{mpsc, oneshot, watch};

const HEADER_BATCH: u16 = 4096;
// Header ranges requested at once from one peer. 16 overran mainnet peers' stream limits
// ("max sub-streams reached", then the peer closed the connection) on a fresh sync.
const HEADER_WINDOW: usize = 4;
const MAX_HEIGHT: u64 = 40_000_000;
// The snapshot is a local cache, never a reason to exhaust phone storage.
// A larger mainnet State requires a separately reviewed mobile storage plan.
const MAX_MOBILE_STAGED_STATE_BYTES: u64 = 2 * 1024 * 1024 * 1024;

#[derive(NetworkBehaviour)]
struct Behaviour {
    profile: rr::Behaviour<NetworkProfileCodec>,
    headers: rr::Behaviour<HeaderSyncCodec>,
    terminal: rr::Behaviour<HistoryStepTerminalCodec>,
    origin: rr::Behaviour<ForkOriginCodec>,
    objects: rr::Behaviour<ObjectCodec>,
    manifest: rr::Behaviour<StateManifestCodec>,
    manifest_page: rr::Behaviour<ManifestPageCodec>,
    segment: rr::Behaviour<StateSegmentCodec>,
    pool: rr::Behaviour<MempoolSyncCodec>,
    identify: identify::Behaviour,
    ping: ping::Behaviour,
}

type Reply<T> = oneshot::Sender<Result<T>>;
enum Command {
    Dial(Multiaddr),
    Headers(PeerId, GetHeadersRequest, Reply<GetHeadersResponse>),
    Terminal(
        PeerId,
        GetHistoryStepTerminalRequest,
        Reply<GetHistoryStepTerminalResponse>,
    ),
    Origin(PeerId, [u8; 32], Reply<ForkOriginResponse>),
    Manifest(PeerId, Reply<GetStateManifestHeader>),
    Page(
        PeerId,
        GetSnapshotManifestPageRequest,
        Reply<GetSnapshotManifestPageResponse>,
    ),
    Segment(
        PeerId,
        GetStateSegmentRequest,
        Reply<GetStateSegmentResponse>,
    ),
    Objects(PeerId, GetObjectsRequest, Reply<GetObjectsResponse>),
    Pool(PeerId, MempoolRequest, Reply<GetMempoolResponse>),
}

#[derive(Clone)]
pub(crate) struct Network {
    commands: mpsc::Sender<Command>,
    peers: watch::Receiver<Vec<PeerId>>,
    lifecycle: Option<tokio_util::sync::CancellationToken>,
}

struct Connection {
    bank: [u8; 32],
    route: Option<crate::network_route::Route>,
    network: Network,
    executor: tokio::runtime::Runtime,
}
thread_local! { static CONNECTION: RefCell<Option<Connection>> = const { RefCell::new(None) }; }
fn with_connection<T>(
    bank: [u8; 32],
    profile: NetworkProfile,
    work: impl FnOnce(&tokio::runtime::Runtime, Network) -> Result<T>,
) -> Result<T> {
    CONNECTION.with(|slot| {
        let mut slot = slot
            .try_borrow_mut()
            .map_err(|_| anyhow::anyhow!("Node connection is busy"))?;
        let route = crate::network_route::current();
        let usable = slot.as_ref().is_some_and(|c| {
            c.bank == bank
                && c.route == route
                && !c.network.commands.is_closed()
                && !c
                    .network
                    .lifecycle
                    .as_ref()
                    .is_some_and(|t| t.is_cancelled())
        });
        if !usable {
            *slot = None;
            let executor = tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .build()?;
            let network = executor.block_on(Network::start(profile))?;
            *slot = Some(Connection {
                bank,
                route,
                network,
                executor,
            });
        }
        let connection = slot.as_ref().expect("node connection initialized");
        work(&connection.executor, connection.network.clone())
    })
}

fn protocols(suffix: &str, support: ProtocolSupport) -> Vec<(StreamProtocol, ProtocolSupport)> {
    vec![(
        StreamProtocol::try_from_owned(format!(
            "{}{suffix}",
            NetworkConfig::mainnet().p2p_protocol_id
        ))
        .expect("compiled network protocol"),
        support,
    )]
}

fn peak_memory_kib() -> Option<u64> {
    fs::read_to_string("/proc/self/status")
        .ok()?
        .lines()
        .find_map(|line| {
            line.strip_prefix("VmHWM:")?
                .split_whitespace()
                .next()?
                .parse()
                .ok()
        })
}

impl Network {
    async fn start(profile: NetworkProfile) -> Result<Self> {
        let lifecycle = crate::mobile_control::token();
        let stop = lifecycle.clone();
        let identity = libp2p::identity::Keypair::generate_ed25519();
        let transport = crate::network_route::transport(&identity)?;
        let mut swarm = SwarmBuilder::with_existing_identity(identity)
            .with_tokio()
            .with_other_transport(|_| transport)?
            .with_behaviour(|key| Behaviour {
                profile: rr::Behaviour::new(
                    protocols("/sync/profile/6", ProtocolSupport::Full),
                    rr::Config::default().with_request_timeout(Duration::from_secs(15)),
                ),
                headers: rr::Behaviour::new(
                    [
                        protocols("/sync/headers/5", ProtocolSupport::Full),
                        protocols("/sync/headers/4", ProtocolSupport::Full),
                    ]
                    .concat(),
                    rr::Config::default()
                        .with_request_timeout(Duration::from_secs(30))
                        .with_max_concurrent_streams(16),
                ),
                terminal: rr::Behaviour::new(
                    protocols("/sync/history-step/1", ProtocolSupport::Outbound),
                    rr::Config::default().with_request_timeout(Duration::from_secs(60)),
                ),
                origin: rr::Behaviour::new(
                    protocols("/sync/fork-origin/1", ProtocolSupport::Outbound),
                    rr::Config::default().with_request_timeout(Duration::from_secs(60)),
                ),
                objects: rr::Behaviour::new(
                    protocols("/sync/objects/2", ProtocolSupport::Full),
                    rr::Config::default().with_max_concurrent_streams(2),
                ),
                manifest: rr::Behaviour::new(
                    protocols("/sync/manifest/7", ProtocolSupport::Full),
                    rr::Config::default().with_max_concurrent_streams(2),
                ),
                manifest_page: rr::Behaviour::new(
                    protocols("/sync/manifest-page/1", ProtocolSupport::Full),
                    rr::Config::default().with_max_concurrent_streams(2),
                ),
                segment: rr::Behaviour::new(
                    protocols("/sync/segment/7", ProtocolSupport::Outbound),
                    rr::Config::default()
                        .with_request_timeout(Duration::from_secs(45))
                        .with_max_concurrent_streams(4),
                ),
                pool: rr::Behaviour::new(
                    [
                        protocols("/sync/mempool/4", ProtocolSupport::Outbound),
                        protocols("/sync/mempool/3", ProtocolSupport::Outbound),
                    ]
                    .concat(),
                    rr::Config::default()
                        .with_request_timeout(Duration::from_secs(20))
                        .with_max_concurrent_streams(4),
                ),
                identify: identify::Behaviour::new(
                    identify::Config::new("/noid/1.0.0".into(), key.public())
                        .with_agent_version("paramo1d/0.1.0".into()),
                ),
                ping: ping::Behaviour::new(ping::Config::new()),
            })?
            .with_swarm_config(|c| c.with_idle_connection_timeout(Duration::from_secs(180)))
            .build();
        let (commands, mut receive) = mpsc::channel(32);
        let (peer_sender, peers) = watch::channel(Vec::new());
        let discovery_commands = commands.clone();
        let protected = crate::network_route::current().is_some();
        tokio::spawn(async move {
            if protected {
                for host in NetworkConfig::mainnet().dns_seeds {
                    if let Ok(address) = format!("/dns4/{host}/tcp/9600").parse() {
                        let _ = discovery_commands.send(Command::Dial(address)).await;
                    }
                }
                return;
            }
            let mut lookups = FuturesUnordered::new();
            for host in NetworkConfig::mainnet().dns_seeds {
                lookups.push(async move {
                    let resolved = tokio::time::timeout(
                        Duration::from_secs(5),
                        tokio::net::lookup_host((*host, 9600)),
                    )
                    .await;
                    (host, resolved)
                });
            }
            while let Some((host, resolved)) = lookups.next().await {
                match resolved {
                    Ok(Ok(found)) => {
                        for address in found.take(2) {
                            let addr: Multiaddr = match address.ip() {
                                std::net::IpAddr::V4(ip) => {
                                    format!("/ip4/{ip}/tcp/{}", address.port())
                                        .parse()
                                        .expect("typed socket multiaddress")
                                }
                                std::net::IpAddr::V6(ip) => {
                                    format!("/ip6/{ip}/tcp/{}", address.port())
                                        .parse()
                                        .expect("typed socket multiaddress")
                                }
                            };
                            let _ = discovery_commands.send(Command::Dial(addr)).await;
                        }
                    }
                    _ => eprintln!("  Discovery: {host} unavailable"),
                }
            }
        });
        tokio::spawn(async move {
            let mut identified = HashSet::new();
            let mut compatible = HashSet::new();
            let mut handshakes = HashSet::new();
            let mut pending_headers: HashMap<
                rr::OutboundRequestId,
                (PeerId, GetHeadersRequest, Reply<GetHeadersResponse>),
            > = HashMap::new();
            let mut pending_terminal: HashMap<
                rr::OutboundRequestId,
                (
                    PeerId,
                    GetHistoryStepTerminalRequest,
                    Reply<GetHistoryStepTerminalResponse>,
                ),
            > = HashMap::new();
            let mut pending_origin: HashMap<
                rr::OutboundRequestId,
                (PeerId, [u8; 32], Reply<ForkOriginResponse>),
            > = HashMap::new();
            let mut pending_manifest =
                HashMap::<rr::OutboundRequestId, (PeerId, Reply<GetStateManifestHeader>)>::new();
            let mut pending_page = HashMap::<
                rr::OutboundRequestId,
                (PeerId, Reply<GetSnapshotManifestPageResponse>),
            >::new();
            let mut pending_segment =
                HashMap::<rr::OutboundRequestId, (PeerId, Reply<GetStateSegmentResponse>)>::new();
            let mut pending_objects =
                HashMap::<rr::OutboundRequestId, (PeerId, Reply<GetObjectsResponse>)>::new();
            let mut pending_pool =
                HashMap::<rr::OutboundRequestId, (PeerId, Reply<GetMempoolResponse>)>::new();
            loop {
                tokio::select! {
                    _=async {match &stop {Some(t)=>t.cancelled().await,None=>std::future::pending::<()>().await}}=>break,
                    command = receive.recv() => match command {
                        Some(Command::Dial(address)) => { let _ = swarm.dial(address); }
                        Some(Command::Headers(peer, request, reply)) => {
                            let id = swarm.behaviour_mut().headers.send_request(&peer, request.clone());
                            pending_headers.insert(id, (peer, request, reply));
                        }
                        Some(Command::Terminal(peer, request, reply)) => {
                            let id = swarm.behaviour_mut().terminal.send_request(&peer, request.clone());
                            pending_terminal.insert(id, (peer, request, reply));
                        }
                        Some(Command::Origin(peer, request, reply)) => {
                            let id = swarm.behaviour_mut().origin.send_request(&peer, request);
                            pending_origin.insert(id, (peer, request, reply));
                        }
                        Some(Command::Manifest(peer, reply)) => {
                            let id = swarm.behaviour_mut().manifest.send_request(&peer, GetStateManifestRequest { requester_height: 0, requested_manifest_digest: [0; 32] });
                            pending_manifest.insert(id, (peer, reply));
                        }
                        Some(Command::Page(peer, request, reply)) => {
                            let id = swarm.behaviour_mut().manifest_page.send_request(&peer, request);
                            pending_page.insert(id, (peer, reply));
                        }
                        Some(Command::Segment(peer, request, reply)) => {
                            let id = swarm.behaviour_mut().segment.send_request(&peer, request);
                            pending_segment.insert(id, (peer, reply));
                        }
                        Some(Command::Objects(peer, request, reply)) => {
                            let id = swarm.behaviour_mut().objects.send_request(&peer, request);
                            pending_objects.insert(id, (peer, reply));
                        }
                        Some(Command::Pool(peer, request, reply)) => {
                            let id = swarm.behaviour_mut().pool.send_request(&peer, request);
                            pending_pool.insert(id, (peer, reply));
                        }
                        None => break,
                    },
                    event = swarm.select_next_some() => match event {
                        SwarmEvent::ConnectionEstablished { peer_id, .. } => {
                            let short = peer_id.to_string();
                            eprintln!("  P2P        Connected to ...{}", &short[short.len().saturating_sub(8)..]);
                        }
                        SwarmEvent::Behaviour(BehaviourEvent::Identify(identify::Event::Received { peer_id, .. })) => {
                            identified.insert(peer_id);
                            if handshakes.insert(peer_id) {
                                swarm.behaviour_mut().profile.send_request(&peer_id, NetworkProfileRequest { expected_profile_id: profile.profile_id });
                            }
                        }
                        SwarmEvent::Behaviour(BehaviourEvent::Profile(rr::Event::Message { peer, message, .. })) => match message {
                            Message::Request { request, channel, .. } => {
                                if request.expected_profile_id == profile.profile_id {
                                    let _ = swarm.behaviour_mut().profile.send_response(channel, NetworkProfileResponse { profile });
                                    compatible.insert(peer);
                                } else { eprintln!("  PROFILE    Peer uses different verification parameters"); let _ = swarm.disconnect_peer_id(peer); }
                            }
                            Message::Response { response, .. } => {
                                if response.profile == profile { crate::mobile_control::network_progress(); compatible.insert(peer); eprintln!("  PROFILE    Compatible peers: {}", compatible.len()); }
                                else { eprintln!("  PROFILE    Peer uses different verification parameters"); let _ = swarm.disconnect_peer_id(peer); }
                            }
                        },
                        SwarmEvent::Behaviour(BehaviourEvent::Profile(rr::Event::OutboundFailure { error, .. })) => {
                            eprintln!("  PROFILE    Handshake: {error}");
                        }
                        SwarmEvent::Behaviour(BehaviourEvent::Headers(rr::Event::Message { message: Message::Request { channel, .. }, .. })) => {
                            let _ = swarm.behaviour_mut().headers.send_response(channel, GetHeadersResponse { status: DataResponseStatus::Ready, records: Vec::new(), snapshot_boundary: None });
                        }
                        SwarmEvent::Behaviour(BehaviourEvent::Objects(rr::Event::Message { message: Message::Request { request, channel, .. }, .. })) => {
                            let _ = swarm.behaviour_mut().objects.send_response(channel, GetObjectsResponse::unavailable(request.objects));
                        }
                        SwarmEvent::Behaviour(BehaviourEvent::Manifest(rr::Event::Message { message: Message::Request { channel, .. }, .. })) => {
                            let _ = swarm.behaviour_mut().manifest.send_response(channel, GetStateManifestHeader::default());
                        }
                        SwarmEvent::Behaviour(BehaviourEvent::ManifestPage(rr::Event::Message { message: Message::Request { request, channel, .. }, .. })) => {
                            let _ = swarm.behaviour_mut().manifest_page.send_response(channel, GetSnapshotManifestPageResponse::unavailable(request.object));
                        }
                        SwarmEvent::Behaviour(BehaviourEvent::Manifest(rr::Event::Message { peer, message: Message::Response { request_id, response }, .. })) => {
                            if let Some((expected, reply)) = pending_manifest.remove(&request_id) {
                                if !reply.is_closed() { crate::mobile_control::network_progress(); }
                                let _ = reply.send(if peer == expected { Ok(response) } else { Err(anyhow::anyhow!("manifest response peer")) });
                            }
                        }
                        SwarmEvent::Behaviour(BehaviourEvent::ManifestPage(rr::Event::Message { peer, message: Message::Response { request_id, response }, .. })) => {
                            if let Some((expected, reply)) = pending_page.remove(&request_id) {
                                if !reply.is_closed() { crate::mobile_control::network_progress(); }
                                let _ = reply.send(if peer == expected { Ok(response) } else { Err(anyhow::anyhow!("manifest page response peer")) });
                            }
                        }
                        SwarmEvent::Behaviour(BehaviourEvent::Segment(rr::Event::Message { peer, message: Message::Response { request_id, response }, .. })) => {
                            if let Some((expected, reply)) = pending_segment.remove(&request_id) {
                                if !reply.is_closed() { crate::mobile_control::network_progress(); }
                                let _ = reply.send(if peer == expected { Ok(response) } else { Err(anyhow::anyhow!("segment response peer")) });
                            }
                        }
                        SwarmEvent::Behaviour(BehaviourEvent::Objects(rr::Event::Message { peer, message: Message::Response { request_id, response }, .. })) => {
                            if let Some((expected, reply)) = pending_objects.remove(&request_id) {
                                if !reply.is_closed() { crate::mobile_control::network_progress(); }
                                let _ = reply.send(if peer == expected { Ok(response) } else { Err(anyhow::anyhow!("object response peer")) });
                            }
                        }
                        SwarmEvent::Behaviour(BehaviourEvent::Pool(rr::Event::Message { peer, message: Message::Response { request_id, response }, .. })) => {
                            if let Some((expected, reply)) = pending_pool.remove(&request_id) {
                                if !reply.is_closed() { crate::mobile_control::network_progress(); }
                                let _ = reply.send(if peer == expected { Ok(response) } else { Err(anyhow::anyhow!("transaction response peer")) });
                            }
                        }
                        SwarmEvent::Behaviour(BehaviourEvent::Manifest(rr::Event::OutboundFailure { request_id, error, .. })) => {
                            if let Some((_, reply)) = pending_manifest.remove(&request_id) { let _ = reply.send(Err(anyhow::Error::new(error).context("manifest transfer"))); }
                        }
                        SwarmEvent::Behaviour(BehaviourEvent::ManifestPage(rr::Event::OutboundFailure { request_id, error, .. })) => {
                            if let Some((_, reply)) = pending_page.remove(&request_id) { let _ = reply.send(Err(anyhow::anyhow!("manifest page transfer: {error}"))); }
                        }
                        SwarmEvent::Behaviour(BehaviourEvent::Segment(rr::Event::OutboundFailure { request_id, error, .. })) => {
                            if let Some((_, reply)) = pending_segment.remove(&request_id) { let _ = reply.send(Err(anyhow::Error::new(error).context("segment transfer"))); }
                        }
                        SwarmEvent::Behaviour(BehaviourEvent::Objects(rr::Event::OutboundFailure { request_id, error, .. })) => {
                            if let Some((_, reply)) = pending_objects.remove(&request_id) { let _ = reply.send(Err(anyhow::Error::new(error).context("object transfer"))); }
                        }
                        SwarmEvent::Behaviour(BehaviourEvent::Pool(rr::Event::OutboundFailure { request_id, error, .. })) => {
                            if let Some((_, reply)) = pending_pool.remove(&request_id) { let _ = reply.send(Err(anyhow::anyhow!("transaction transfer: {error}"))); }
                        }
                        SwarmEvent::Behaviour(BehaviourEvent::Headers(rr::Event::Message { peer, message: Message::Response { request_id, response }, .. })) => {
                            if let Some((expected, request, reply)) = pending_headers.remove(&request_id) {
                                if !reply.is_closed() { crate::mobile_control::network_progress(); }
                                let result = (|| -> Result<_> {
                                    ensure!(peer == expected, "header response peer");
                                    ensure!(response.records.len() <= request.count as usize, "header response count");
                                    for (i, record) in response.records.iter().enumerate() {
                                        ensure!(record.header.height == request.start_height + i as u64, "header response range");
                                    }
                                    Ok(response)
                                })();
                                let _ = reply.send(result);
                            }
                        }
                        SwarmEvent::Behaviour(BehaviourEvent::Terminal(rr::Event::Message { peer, message: Message::Response { request_id, response }, .. })) => {
                            if let Some((expected, request, reply)) = pending_terminal.remove(&request_id) {
                                if !reply.is_closed() { crate::mobile_control::network_progress(); }
                                let result = (|| -> Result<_> {
                                    ensure!(peer == expected && response.height == request.height && response.block_hash == request.block_hash, "terminal response identity");
                                    Ok(response)
                                })();
                                let _ = reply.send(result);
                            }
                        }
                        SwarmEvent::Behaviour(BehaviourEvent::Origin(rr::Event::Message { peer, message: Message::Response { request_id, response }, .. })) => {
                            if let Some((expected, request, reply)) = pending_origin.remove(&request_id) {
                                if !reply.is_closed() { crate::mobile_control::network_progress(); }
                                let result = (|| -> Result<_> {
                                    ensure!(peer == expected && response.request == request, "origin response identity");
                                    Ok(response)
                                })();
                                let _ = reply.send(result);
                            }
                        }
                        SwarmEvent::Behaviour(BehaviourEvent::Headers(rr::Event::OutboundFailure { request_id, error, .. })) => {
                            if let Some((_, _, reply)) = pending_headers.remove(&request_id) { let _ = reply.send(Err(anyhow::Error::new(error).context("header transfer"))); }
                        }
                        SwarmEvent::Behaviour(BehaviourEvent::Terminal(rr::Event::OutboundFailure { request_id, error, .. })) => {
                            if let Some((_, _, reply)) = pending_terminal.remove(&request_id) { let _ = reply.send(Err(anyhow::Error::new(error).context("terminal transfer"))); }
                        }
                        SwarmEvent::Behaviour(BehaviourEvent::Origin(rr::Event::OutboundFailure { request_id, error, .. })) => {
                            if let Some((_, _, reply)) = pending_origin.remove(&request_id) { let _ = reply.send(Err(anyhow::Error::new(error).context("origin transfer"))); }
                        }
                        SwarmEvent::ConnectionClosed { peer_id, num_established: 0, .. } => {
                            identified.remove(&peer_id); compatible.remove(&peer_id); handshakes.remove(&peer_id);
                        }
                        _ => {}
                    }
                }
                let mut ready: Vec<_> = compatible.intersection(&identified).copied().collect();
                ready.sort();
                let changed = { *peer_sender.borrow() != ready };
                if changed {
                    let _ = peer_sender.send(ready);
                }
            }
        });
        Ok(Self {
            commands,
            peers,
            lifecycle,
        })
    }

    async fn headers(&self, peer: PeerId, first: u64, count: u16) -> Result<GetHeadersResponse> {
        self.headers_with_inventory(peer, first, count, false).await
    }

    pub(crate) async fn headers_with_inventory(
        &self,
        peer: PeerId,
        first: u64,
        count: u16,
        inventory: bool,
    ) -> Result<GetHeadersResponse> {
        for _ in 0..8 {
            let (reply, result) = oneshot::channel();
            self.commands
                .send(Command::Headers(
                    peer,
                    GetHeadersRequest {
                        start_height: first,
                        count,
                        include_inventory: inventory,
                    },
                    reply,
                ))
                .await?;
            let response = result.await??;
            if let DataResponseStatus::Busy { retry_after_ms } = response.status {
                tokio::time::sleep(Duration::from_millis(retry_after_ms as u64)).await;
                continue;
            }
            return Ok(response);
        }
        bail!("peer header serving remained busy")
    }

    async fn terminal(&self, peer: PeerId, height: u64, hash: [u8; 32]) -> Result<Vec<u8>> {
        for _ in 0..3 {
            let (reply, result) = oneshot::channel();
            self.commands
                .send(Command::Terminal(
                    peer,
                    GetHistoryStepTerminalRequest {
                        height,
                        block_hash: hash,
                    },
                    reply,
                ))
                .await?;
            let response = result.await??;
            if let DataResponseStatus::Busy { retry_after_ms } = response.status {
                tokio::time::sleep(Duration::from_millis(retry_after_ms as u64)).await;
                continue;
            }
            return response.terminal_bytes.context("peer terminal unavailable");
        }
        bail!("peer terminal serving remained busy")
    }

    async fn first_terminal(
        &self,
        primary: PeerId,
        height: u64,
        hash: [u8; 32],
    ) -> Result<Vec<u8>> {
        let mut peers = self.peers.borrow().clone();
        peers.retain(|peer| *peer != primary);
        peers.insert(0, primary);
        let mut transfers = FuturesUnordered::new();
        eprintln!("  SOURCES    Requesting proof from {} peers", peers.len());
        for peer in peers.into_iter().take(8) {
            let network = self.clone();
            transfers.push(async move { (peer, network.terminal(peer, height, hash).await) });
        }
        let received = async {
            while let Some((_, result)) = transfers.next().await {
                match result {
                    Ok(bytes) => return Ok(bytes),
                    Err(error) => eprintln!("  SOURCE     Proof response: {error:#}"),
                }
            }
            bail!("mainnet peers could not supply the selected proof")
        };
        tokio::time::timeout(Duration::from_secs(15), received)
            .await
            .context("proof-source response deadline")?
    }

    async fn origin(&self, peer: PeerId, key: [u8; 32]) -> Result<Vec<u8>> {
        let (reply, result) = oneshot::channel();
        self.commands
            .send(Command::Origin(peer, key, reply))
            .await?;
        result.await??.bytes.context("peer origin unavailable")
    }

    pub(crate) async fn ready(&self) -> Result<Vec<PeerId>> {
        let mut peers = self.peers.clone();
        while peers.borrow().is_empty() {
            tokio::time::timeout(Duration::from_secs(20), peers.changed()).await??;
        }
        let ready = peers.borrow().clone();
        Ok(ready)
    }

    pub(crate) async fn manifest(&self, peer: PeerId) -> Result<GetStateManifestHeader> {
        let (reply, result) = oneshot::channel();
        self.commands.send(Command::Manifest(peer, reply)).await?;
        result.await?
    }

    pub(crate) async fn page(
        &self,
        peer: PeerId,
        request: GetSnapshotManifestPageRequest,
    ) -> Result<Vec<u8>> {
        for _ in 0..3 {
            let (reply, result) = oneshot::channel();
            self.commands
                .send(Command::Page(peer, request, reply))
                .await?;
            let response = result.await??;
            ensure!(response.object == request.object, "manifest page identity");
            if let DataResponseStatus::Busy { retry_after_ms } = response.status {
                tokio::time::sleep(Duration::from_millis(retry_after_ms.into())).await;
                continue;
            }
            let bytes = response.data.context("peer manifest page unavailable")?;
            ensure!(
                request.object.page.matches_bytes(&bytes),
                "manifest page digest"
            );
            crate::peer_wallet::record_payload(bytes.len());
            return Ok(bytes.to_vec());
        }
        bail!("peer manifest page remained busy")
    }

    pub(crate) async fn segments(
        &self,
        peer: PeerId,
        request: GetStateSegmentRequest,
    ) -> Result<Vec<(u16, Vec<u8>)>> {
        let requested: Vec<_> = std::iter::once(request.segment_id)
            .chain(request.additional_segments.iter().copied())
            .collect();
        ensure!(
            requested.len() <= noid_p2p::protocol::MAX_STATE_SEGMENT_BATCH
                && requested.windows(2).all(|p| p[0] < p[1]),
            "Segment request order"
        );
        for _ in 0..3 {
            let (reply, result) = oneshot::channel();
            self.commands
                .send(Command::Segment(peer, request.clone(), reply))
                .await?;
            let response = result.await??;
            ensure!(
                response.segment_id == request.segment_id
                    && response.expected_tip_height == request.expected_tip_height
                    && response.expected_tip_hash == request.expected_tip_hash
                    && response.manifest_digest == request.manifest_digest,
                "Segment response identity"
            );
            if let DataResponseStatus::Busy { retry_after_ms } = response.status {
                tokio::time::sleep(Duration::from_millis(retry_after_ms.into())).await;
                continue;
            }
            let mut parts = Vec::new();
            if let Some(bytes) = response.data {
                parts.push((response.segment_id, bytes));
            }
            parts.extend(
                response
                    .additional_segments
                    .into_iter()
                    .map(|p| (p.segment_id, p.data)),
            );
            ensure!(
                !parts.is_empty()
                    && parts.len() <= requested.len()
                    && parts.windows(2).all(|p| p[0].0 < p[1].0)
                    && parts.iter().all(|p| requested.binary_search(&p.0).is_ok()),
                "Segment response selection"
            );
            for (_, bytes) in &parts {
                crate::peer_wallet::record_payload(bytes.len());
            }
            return Ok(parts);
        }
        bail!("Peer State segments remained busy")
    }

    pub(crate) async fn object(&self, peer: PeerId, object: ObjectId) -> Result<Vec<u8>> {
        for _ in 0..3 {
            let (reply, result) = oneshot::channel();
            self.commands
                .send(Command::Objects(
                    peer,
                    GetObjectsRequest {
                        objects: vec![object],
                    },
                    reply,
                ))
                .await?;
            let mut response = result.await??;
            if let DataResponseStatus::Busy { retry_after_ms } = response.status {
                tokio::time::sleep(Duration::from_millis(retry_after_ms.into())).await;
                continue;
            }
            ensure!(
                response.objects.len() == 1 && response.objects[0].object == object,
                "object response identity"
            );
            let bytes = response
                .objects
                .remove(0)
                .bytes
                .context("peer block body unavailable")?;
            ensure!(object.matches_bytes(&bytes), "block object digest");
            crate::peer_wallet::record_payload(bytes.len());
            return Ok(bytes);
        }
        bail!("peer block body remained busy")
    }


    /// Fetch block bodies named by a peer's header inventory. Each returned
    /// byte string matches its object digest and length; whether the body
    /// belongs to the verified chain is checked again when it is applied.
    async fn block_bodies(&self, peer: PeerId, ids: &[noid_p2p::object_protocol::BlockBodyObjectId]) -> Result<Vec<Vec<u8>>> {
        let mut bodies = Vec::with_capacity(ids.len());
        for chunk in ids.chunks(noid_p2p::object_protocol::MAX_OBJECTS_PER_REQUEST) {
            let objects: Vec<ObjectId> = chunk.iter().copied().map(ObjectId::BlockBody).collect();
            let mut attempts = 0;
            let response = loop {
                let (reply, result) = oneshot::channel();
                self.commands
                    .send(Command::Objects(peer, GetObjectsRequest { objects: objects.clone() }, reply))
                    .await?;
                let response = result.await??;
                if let DataResponseStatus::Busy { retry_after_ms } = response.status {
                    attempts += 1;
                    ensure!(attempts <= 4, "peer block body serving remained busy");
                    tokio::time::sleep(peer_retry_delay(retry_after_ms as u64)).await;
                    continue;
                }
                break response;
            };
            for (payload, id) in response.objects.into_iter().zip(chunk) {
                let bytes = payload.bytes.context("peer no longer serves a recent block body")?;
                ensure!(id.matches_bytes(&bytes), "block body differs from its advertised digest");
                bodies.push(bytes);
            }
        }
        ensure!(bodies.len() == ids.len(), "incomplete block body transfer");
        Ok(bodies)
    }

    /// iOS: assemble and semantically verify a peer's complete State manifest.
    async fn verified_manifest(&self, peer: PeerId) -> Result<noid_p2p::protocol::VerifiedStateManifest> {
        let header = self.manifest(peer).await?;
        ensure!(header.tip_height > 0 && header.tip_height < MAX_HEIGHT, "snapshot manifest boundary");
        let snapshot: noid_p2p::object_protocol::SnapshotId = header.snapshot_id().context("invalid snapshot identity")?;
        let mut pages = Vec::with_capacity(header.descriptor_pages.len());
        for page in &header.descriptor_pages {
            let object = noid_p2p::protocol::SnapshotManifestPageObjectId { snapshot, page: *page };
            pages.push(self.page(peer, GetSnapshotManifestPageRequest { object }).await?);
        }
        // Exact page hashes (checked by `page`) bind the descriptors to the header.
        // The verifier below checks cross-page order, lengths, and State geometry.
        let mut segments = Vec::new();
        let mut roots = Vec::new();
        let mut lengths = Vec::new();
        for (page, bytes) in header.descriptor_pages.iter().zip(&pages) {
            let decoded = noid_p2p::protocol::decode_snapshot_manifest_page(*page, bytes)
                .context("invalid snapshot descriptor page")?;
            for (id, root, length) in decoded {
                segments.push(id); roots.push(root); lengths.push(length);
            }
        }
        ensure!(segments.len() == header.segment_count as usize, "snapshot descriptor count");
        let response = noid_p2p::protocol::GetStateManifestResponse {
            tip_height: header.tip_height, tip_hash: header.tip_hash,
            cumulative_chainwork: header.cumulative_chainwork,
            format_version: header.format_version, state_root: header.state_root,
            manifest_digest: header.manifest_digest, log_slots: header.log_slots,
            active_slot_count: header.active_slot_count, alloc_counter: header.alloc_counter,
            eff_log: header.eff_log, bridge_tip_height: header.bridge_tip_height,
            bridge_tip_hash: header.bridge_tip_hash,
            bridge_cumulative_chainwork: header.bridge_cumulative_chainwork,
            segment_ids: segments, segment_roots: roots, segment_lengths: lengths,
        };
        let verified = noid_p2p::protocol::VerifiedStateManifest::verify(response)
            .context("snapshot descriptors failed semantic verification")?;
        ensure!(verified.clone().into_arc().manifest_digest == header.manifest_digest,
            "snapshot descriptor digest changed during assembly");
        Ok(verified)
    }

    async fn segment(
        &self,
        peer: PeerId,
        manifest: &noid_p2p::protocol::GetStateManifestResponse,
        segment_id: u16,
    ) -> Result<GetStateSegmentResponse> {
        ensure!(manifest.segment_ids.binary_search(&segment_id).is_ok(),
            "segment absent from verified manifest");
        let (reply, result) = oneshot::channel();
        self.commands.send(Command::Segment(peer, GetStateSegmentRequest {
            segment_id, additional_segments: Vec::new(),
            expected_tip_height: manifest.tip_height,
            expected_tip_hash: manifest.tip_hash,
            manifest_digest: manifest.manifest_digest,
        }, reply)).await?;
        result.await?
    }

    pub(crate) async fn pool(
        &self,
        peer: PeerId,
        request: MempoolRequest,
    ) -> Result<GetMempoolResponse> {
        let (reply, result) = oneshot::channel();
        self.commands
            .send(Command::Pool(peer, request, reply))
            .await?;
        result.await?
    }
}

pub(crate) fn with_peers<T>(
    artifacts: &Path,
    work: impl FnOnce(&tokio::runtime::Runtime, Network) -> Result<T>,
) -> Result<T> {
    let legacy = artifacts::read_bounded(&artifacts.join("legacy"), 4 * 1024 * 1024)?;
    ensure!(legacy.len() >= 32, "released profile length");
    let bank = legacy[legacy.len() - 32..].try_into()?;
    with_connection(bank, NetworkProfile::for_proof_bank(bank), work)
}

pub(crate) async fn discover(
    network: &mut Network,
) -> Result<Vec<(PeerId, noid_p2p::object_protocol::ChainPoint)>> {
    let _waiting = crate::mobile_control::waiting_for_network("peer-discovery");
    let start = Instant::now();
    let starting = network.peers.borrow().is_empty();
    loop {
        let waiting = { network.peers.borrow().is_empty() };
        if !waiting {
            break;
        }
        tokio::time::timeout(Duration::from_secs(20), network.peers.changed()).await??;
    }
    // Let independent startup dials finish before selecting a source.
    if starting {
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    let peers = network.peers.borrow().clone();
    let mut queries = FuturesUnordered::new();
    for peer in peers {
        let network = network.clone();
        queries.push(async move {
            let result = async {
                let response = network.headers(peer, 0, 1).await?;
                ensure!(
                    response.records.first().is_some_and(
                        |r| r.header == noid_chain::consensus::genesis::genesis_header()
                    ),
                    "Peer genesis differs"
                );
                let base = response
                    .snapshot_boundary
                    .context("Peer has no proof boundary")?;
                ensure!(base.height < MAX_HEIGHT, "Peer height budget");
                // Prefer the newest proof the peer advertises, but keep its snapshot
                // boundary as a fallback: a freshly advertised proof is often not yet
                // servable by any peer, and failing on it left the wallet with no balance.
                let mut points = vec![base];
                if let Ok(tail) = network
                    .headers_with_inventory(peer, base.height + 1, 64, true)
                    .await
                {
                    if let Some(record) = tail.records.iter().rev().find(|r| r.terminal.is_some()) {
                        points.insert(0, noid_p2p::object_protocol::ChainPoint::new(
                            record.header.height,
                            block_id(&record.header),
                        ));
                    }
                }
                Ok::<_, anyhow::Error>(points)
            }
            .await;
            (peer, result)
        });
    }
    let mut candidates = Vec::new();
    while let Some((peer, response)) = queries.next().await {
        if let Ok(points) = response {
            for boundary in points {
                // One attempt per distinct proof point: each transfer already asks up to
                // eight peers, so repeating the same point only adds 15 s timeouts.
                if !candidates.iter().any(|(_, seen)| *seen == boundary) {
                    candidates.push((peer, boundary));
                }
            }
        }
    }
    ensure!(
        !candidates.is_empty(),
        "mainnet peers have no usable proof boundary"
    );
    candidates.sort_by_key(|(_, point)| std::cmp::Reverse(point.height));
    eprintln!(
        "  PEERS      {} compatible sources in {:.2}s",
        candidates.len(),
        start.elapsed().as_secs_f64()
    );
    Ok(candidates)
}

async fn fetch_bundle(
    network: &Network,
    peer: PeerId,
    boundary: noid_p2p::object_protocol::ChainPoint,
    output: &Path,
    verifier: &Verifier,
    previous: Option<&Path>,
) -> Result<()> {
    let _waiting = crate::mobile_control::waiting_for_network("proof-download");
    ensure!(!output.exists(), "sync bundle already exists");
    let temporary = tempfile::Builder::new()
        .prefix(".receiving-")
        .tempdir_in(output.parent().context("sync directory")?)?;
    let began = Instant::now();
    eprintln!("  DOWNLOAD   Mainnet block {}", boundary.height);
    let terminal = network
        .first_terminal(peer, boundary.height, boundary.hash)
        .await?;
    let metadata = HistoryStepTerminalMetadata::decode_prefix(&terminal)?;
    ensure!(
        metadata.terminal_height() == boundary.height,
        "terminal boundary height"
    );
    fs::write(temporary.path().join("terminal.bin"), &terminal)?;
    let mut files = BTreeMap::new();
    let current = params::v2_1_active(boundary.height);
    let key = verifier.claimed_origin_request(&terminal)?;
    let origin_network = network.clone();
    let cache_name = if current {
        "current-origin.bin"
    } else {
        "origin.bin"
    };
    let cached_origin = previous.and_then(|directory| {
        let same_key = artifacts::read_bounded(&directory.join("origin-key.bin"), 32)
            .ok()
            .is_some_and(|saved| saved == key);
        same_key
            .then(|| {
                artifacts::read_bounded(&directory.join(cache_name), artifacts::MAX_ORIGIN_BYTES)
                    .ok()
            })
            .flatten()
    });
    let origin_reused = cached_origin.is_some();
    let origin_task = tokio::spawn(async move {
        if let Some(bytes) = cached_origin {
            Ok(bytes)
        } else {
            origin_network.origin(peer, key).await
        }
    });
    let mut headers = File::create(temporary.path().join("headers.bin"))?;
    let mut first = 0;
    if let Some(previous) = previous {
        let mut accepted = File::open(previous.join("headers.bin"))?;
        let length = accepted.metadata()?.len();
        ensure!(
            length % 212 == 0 && length <= MAX_HEIGHT * 212,
            "accepted header prefix length"
        );
        let cached_count = length / 212;
        let candidate_count = boundary.height + 1;
        let reusable_limit = cached_count.min(candidate_count);
        // iOS (BadParentHash fix): a new source can advertise a valid terminal on a
        // different fork. Never splice its suffix onto our accepted headers without
        // first checking that the source shares the overlap. Headers are hash-linked,
        // so agreement at one height implies agreement below it: find the highest
        // shared header with an exponential step back and a binary search. Full
        // header consensus, terminal, origin and recursive State checks still decide.
        let reusable = shared_header_prefix(network, peer, &mut accepted, reusable_limit).await?;
        if reusable < reusable_limit {
            eprintln!(
                "  FORK       Peer differs from saved chain above block {}; downloading {} headers",
                reusable.saturating_sub(1),
                candidate_count - reusable
            );
        }
        accepted.seek(SeekFrom::Start(0))?;
        let prefix = reusable * 212;
        let copied = std::io::copy(&mut std::io::Read::take(&mut accepted, prefix), &mut headers)?;
        ensure!(copied == prefix, "accepted header prefix changed");
        first = reusable;
    }
    let mut pending = FuturesUnordered::new();
    let mut total = 0u64;
    crate::mobile_control::begin_transfer(boundary.height + 1 - first);
    while first <= boundary.height || !pending.is_empty() {
        while first <= boundary.height && pending.len() < HEADER_WINDOW {
            let count = (boundary.height + 1 - first).min(HEADER_BATCH as u64) as u16;
            let network = network.clone();
            pending.push(async move {
                // iOS: a candidate's proof is checked against one coherent header
                // chain. Mixing ranges from different peers can splice forks.
                // A dropped stream or a closed connection is retried on the same peer with a
                // short backoff instead of failing the whole candidate (the ranges must still
                // come from one peer so the proof is checked against one coherent chain).
                let mut attempt = 0u32;
                let response = loop {
                    match network.headers(peer, first, count).await {
                        Ok(response) => break Ok(response),
                        Err(error) if attempt < 4 => {
                            attempt += 1;
                            eprintln!("  RETRY      Header range {first}+{count}: {error:#}");
                            tokio::time::sleep(Duration::from_millis(500u64 << attempt)).await;
                        }
                        Err(error) => break Err(error),
                    }
                };
                (first, count, response)
            });
            first += count as u64;
        }
        let (at, count, result) = pending.next().await.context("header transfer wave")?;
        let response = result?;
        if let DataResponseStatus::Busy { retry_after_ms } = response.status {
            tokio::time::sleep(peer_retry_delay(retry_after_ms as u64)).await;
            let response = network.headers(peer, at, count).await?;
            ensure!(
                response.records.len() == count as usize,
                "incomplete retried header range"
            );
            headers.seek(SeekFrom::Start(at * 212))?;
            for record in response.records {
                headers.write_all(&record.header.to_bytes())?;
            }
        } else {
            ensure!(
                response.records.len() == count as usize,
                "incomplete header range"
            );
            headers.seek(SeekFrom::Start(at * 212))?;
            for record in response.records {
                headers.write_all(&record.header.to_bytes())?;
            }
        }
        total += count as u64;
        crate::mobile_control::transferred(total);
        eprint!("\r  HEADERS    {total}/{} received", boundary.height + 1);
    }
    headers.sync_all()?;
    crate::mobile_control::clear_transfer();
    let origin = origin_task.await??;
    fs::write(temporary.path().join("origin-key.bin"), key)?;
    if current {
        let certificate = noid_recursive::acceptance::history_step::v2::capacity_banked::AuthorizationOriginCertificate::from_bytes(&origin)
            .map_err(|e| anyhow::anyhow!("current origin codec: {e}"))?;
        let previous = if certificate.previous_origin_bytes().is_empty() {
            network
                .origin(peer, certificate.previous_origin_request())
                .await?
        } else {
            certificate.previous_origin_bytes().to_vec()
        };
        fs::write(temporary.path().join("origin.bin"), &previous)?;
        files.insert("origin.bin", previous.len());
        fs::write(temporary.path().join("current-origin.bin"), &origin)?;
    } else {
        fs::write(temporary.path().join("origin.bin"), &origin)?;
    }
    files.insert(
        if current {
            "current-origin.bin"
        } else {
            "origin.bin"
        },
        origin.len(),
    );
    let mut header_file = File::open(temporary.path().join("headers.bin"))?;
    let header = crate::headers::read_header(&mut header_file, boundary.height)?;
    ensure!(
        block_id(&header) == boundary.hash
            && semantic_header_id(&header) == metadata.terminal_hash(),
        "downloaded proof boundary identity"
    );
    let manifest = serde_json::json!({"schema":1,"network":artifacts::profile().network,"height":boundary.height,"block_hash":hex::encode(boundary.hash),"headers":boundary.height+1,"header_bytes":(boundary.height+1)*212,"proof_bytes":terminal.len(),"origin_bytes":files.values().sum::<usize>(),"transport":"direct-p2p"});
    fs::write(
        temporary.path().join("bundle.json"),
        serde_json::to_vec_pretty(&manifest)?,
    )?;
    if let Err(error) =
        crate::peer_wallet::prepare_candidate(network, temporary.path(), output, boundary.height)
            .await
    {
        crate::mobile_control::check()?;
        eprintln!("  WALLET     Prefetch deferred: {error:#}");
    }
    crate::mobile_control::verifying();
    fs::rename(temporary.path(), output)?;
    eprintln!(
        "\n  RECEIVED   {:.2} MiB in {:.2}s",
        (total * 212
            + terminal.len() as u64
            + if origin_reused {
                0
            } else {
                files.values().sum::<usize>() as u64
            }) as f64
            / 1048576.0,
        began.elapsed().as_secs_f64()
    );
    Ok(())
}

/// Stage a complete State snapshot from the dedicated segment protocol. The
/// caller must supply a header independently accepted by the mobile verifier;
/// no peer-supplied manifest may authenticate its own State root. This returns
/// a temporary finalized handle, not an installed or spendable wallet State.
async fn stage_state(
    network: &Network,
    peer: PeerId,
    manifest: &noid_p2p::protocol::GetStateManifestResponse,
    accepted_header: BlockHeader,
    parent: &Path,
) -> Result<FinalizedSnapshotStaging> {
    ensure!(
        manifest.tip_height == accepted_header.height
            && manifest.tip_hash == block_id(&accepted_header)
            && manifest.state_root == accepted_header.state_root
            && manifest.log_slots == accepted_header.log_slots
            && manifest.active_slot_count == accepted_header.active_slot_count
            && manifest.alloc_counter == accepted_header.alloc_counter,
        "State manifest differs from the independently verified chain boundary"
    );
    ensure!(manifest.has_valid_manifest_digest(), "invalid State manifest identity");
    let mut total = 0u64;
    for length in &manifest.segment_lengths {
        total = total.checked_add(u64::from(*length)).context("State size overflow")?;
        ensure!(total <= MAX_MOBILE_STAGED_STATE_BYTES, "State exceeds mobile staging limit");
    }
    let metadata = AuthenticatedSnapshotMetadata::from_authenticated_header(
        accepted_header, manifest.tip_hash, manifest.eff_log,
    )?;
    let descriptors = manifest.segment_ids.iter().zip(&manifest.segment_roots)
        .zip(&manifest.segment_lengths)
        .map(|((&segment_id, &segment_root), &encoded_len)| SnapshotSegmentDescriptor {
            segment_id, segment_root, encoded_len,
        })
        .collect();
    let mut staging = SnapshotStagingSession::new(parent, metadata, descriptors)?;
    crate::mobile_control::begin_transfer(manifest.segment_ids.len() as u64);
    let mut sources = vec![peer];
    for candidate in network.peers.borrow().iter().copied() {
        if !sources.contains(&candidate) && sources.len() < 4 { sources.push(candidate); }
    }
    for (index, &segment_id) in manifest.segment_ids.iter().enumerate() {
        crate::mobile_control::check()?;
        let mut accepted = false;
        for source in &sources {
            match network.segment(*source, manifest, segment_id).await {
                Ok(response) => {
                    if let Some(bytes) = response.data {
                        if staging.accept_segment_recoverable(segment_id, response.eff_log, &bytes).is_ok() {
                            accepted = true;
                            break;
                        }
                    }
                }
                Err(error) => eprintln!("  STATE      Segment {segment_id} peer retry: {error:#}"),
            }
        }
        ensure!(accepted, "State segment {segment_id} unavailable or failed authenticated validation");
        crate::mobile_control::transferred((index + 1) as u64);
    }
    let finalized = staging.finalize()?;
    crate::mobile_control::clear_transfer();
    Ok(finalized)
}

/// Most recent blocks a phone will apply after a snapshot. `discover` moves
/// the proof boundary at most 64 blocks past a peer's snapshot boundary, and
/// peers keep recent bodies for their reorg window.
const MAX_NATIVE_SUFFIX_BLOCKS: u64 = 64;
/// Bring installed asset State from its snapshot block up to the verified
/// proof boundary, so token/NFT planning and the verified chain name the same
/// block. Without this the snapshot nearly always lags the boundary and
/// gateway-free sends can never start.
///
/// Uses upstream's recursive-suffix path: the boundary terminal (already
/// verified by the mobile verifier, and re-bound here byte-for-byte) authorizes
/// the suffix, then each body passes native header, epoch-anchor, transaction
/// and exact State-root checks in `apply_verified_recursive_suffix_block`.
/// Every body header must also equal the mobile verifier's header at that
/// height. All bodies are downloaded before any durable write.
async fn advance_native_suffix(
    network: &Network,
    sources: &[PeerId],
    state: &crate::VerifiedState,
    directory: &Path,
    verifier: &mut crate::verifier_session::Session,
    native_db: &Path,
) -> Result<serde_json::Value> {
    let target = state.height();
    let (base, base_hash) = {
        let context = MdbxChainContext::open_or_create(native_db)?;
        (context.tip_height(), context.tip_hash())
    };
    if base >= target {
        bail!("asset State is not behind the verified boundary");
    }
    ensure!(target - base <= MAX_NATIVE_SUFFIX_BLOCKS,
        "asset State is {} blocks behind; waiting for a newer snapshot", target - base);
    ensure!(block_id(&verifier.checked_header(base)?) == base_hash,
        "installed asset State is not on the verified chain");
    let tip_header = verifier.checked_header(target)?;
    ensure!(hex::encode(block_id(&tip_header)) == state.block_hash(),
        "verified boundary header changed");
    let anchor_height = noid_chain::consensus::epoch_anchor::tx_epoch_anchor_height_for_child(target);
    let anchor_header = verifier.checked_header(anchor_height)?;
    let terminal = artifacts::read_bounded(&directory.join("terminal.bin"), 1_100_000)?;
    let count = (target - base) as u16;
    let mut expected = Vec::with_capacity(count as usize);
    for height in base + 1..=target {
        expected.push(verifier.checked_header(height)?);
    }

    let mut bodies = None;
    let mut last_error = None;
    for &peer in sources.iter().take(4) {
        crate::mobile_control::check()?;
        let attempt = async {
            let inventory = network.headers_with_inventory(peer, base + 1, count, true).await?;
            ensure!(inventory.records.len() == count as usize, "incomplete recent block inventory");
            let mut ids = Vec::with_capacity(count as usize);
            for (record, header) in inventory.records.iter().zip(&expected) {
                ensure!(record.header == *header, "peer block inventory is on another fork");
                ids.push(record.body.context("peer does not serve a recent block body")?);
            }
            let received = network.block_bodies(peer, &ids).await?;
            anyhow::Ok(received)
        };
        match tokio::time::timeout(Duration::from_secs(60), attempt).await {
            Ok(Ok(received)) => { bodies = Some(received); break; }
            Ok(Err(error)) => { eprintln!("  NATIVE     Recent blocks from peer: {error:#}"); last_error = Some(error); }
            Err(_) => { eprintln!("  NATIVE     Recent blocks from peer timed out"); last_error = Some(anyhow::anyhow!("recent block transfer timed out")); }
        }
    }
    let bodies = match bodies {
        Some(bodies) => bodies,
        None => return Err(last_error.unwrap_or_else(|| anyhow::anyhow!("no peer for recent blocks"))),
    };

    let mut context = MdbxChainContext::open_or_create(native_db)?;
    ensure!(context.tip_height() == base && context.tip_hash() == base_hash,
        "asset State changed while recent blocks downloaded");
    let mut authority = context.verify_recursive_suffix(tip_header, anchor_header, terminal.clone(), |claim| {
        if claim.terminal_bytes != terminal.as_slice() || claim.header != tip_header || claim.epoch_anchor_header != anchor_header {
            return Err("HistoryStep input differs from independently verified bundle".into());
        }
        Ok(())
    })?;
    for bytes in &bodies {
        crate::mobile_control::check()?;
        let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_secs();
        context.apply_verified_recursive_suffix_block(&mut authority, bytes, now, |block, chain_state| {
            noid_chain::materialize_accepted_block_state(chain_state, block).map_err(|error| format!("{error:?}"))
        }).context("recent block failed native application")?;
    }
    ensure!(authority.is_complete() && context.tip_hash() == block_id(&tip_header),
        "asset State did not reach the verified boundary");
    eprintln!("  NATIVE     Applied {} recent blocks; asset State at block {target}", bodies.len());
    Ok(serde_json::json!({
        "height": target, "block_hash": hex::encode(block_id(&tip_header)),
        "state_root": hex::encode(tip_header.state_root), "applied_blocks": bodies.len()
    }))
}

/// Install the newest usable snapshot, then apply recent verified blocks so
/// asset State reaches the verified boundary. A catch-up failure keeps the
/// snapshot result (display only; Send stays blocked) and reports why.
async fn ensure_native_state(
    network: &Network,
    peer: PeerId,
    state: &crate::VerifiedState,
    directory: &Path,
    verifier: &mut crate::verifier_session::Session,
    artifacts: &Path,
    data_directory: &Path,
) -> Result<serde_json::Value> {
    let mut installed = ensure_native_snapshot(network, peer, state, directory, verifier, artifacts, data_directory).await?;
    let behind = installed["height"].as_u64().is_some_and(|height| height < state.height());
    if !behind {
        return Ok(installed);
    }
    let mut sources = vec![peer];
    for candidate in network.peers.borrow().iter().copied() {
        if !sources.contains(&candidate) { sources.push(candidate); }
    }
    let native_db = data_directory.join("NativeState");
    // Foreground sync runs every 30 s. Do not re-download the same recent
    // blocks for a boundary whose catch-up just failed.
    let marker = data_directory.join("native-catchup-failure.json");
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_secs();
    if let Ok(bytes) = artifacts::read_bounded(&marker, 4096) {
        if let Ok(saved) = serde_json::from_slice::<serde_json::Value>(&bytes) {
            let same_target = saved["target"].as_u64() == Some(state.height());
            let recent = saved["at"].as_u64().is_some_and(|at| now.saturating_sub(at) < 300);
            if same_target && recent {
                let issue = saved["error"].as_str().unwrap_or("catch-up failed").to_owned();
                installed["sync_issue"] = serde_json::json!(issue);
                return Ok(installed);
            }
        }
    }
    match advance_native_suffix(network, &sources, state, directory, verifier, &native_db).await {
        Ok(advanced) => {
            let _ = fs::remove_file(&marker);
            Ok(advanced)
        }
        Err(error) => {
            eprintln!("  NATIVE     Catch-up to verified block: {error:#}");
            let summary: String = format!("catch-up to block {}: {error}", state.height()).chars().take(200).collect();
            let _ = fs::write(&marker, serde_json::to_vec(&serde_json::json!({"target": state.height(), "at": now, "error": summary}))?);
            let previous = installed.get("sync_issue").and_then(|v| v.as_str()).map(str::to_owned);
            let issue = format!("catch-up to block {}: {error}", state.height());
            installed["sync_issue"] = serde_json::json!(match previous { Some(p) => format!("{p}; {issue}"), None => issue });
            Ok(installed)
        }
    }
}

/// Install a snapshot even when the recursive proof was already accepted on
/// an earlier launch. This prevents a failed first download from permanently
/// leaving a phone without NFT discovery until the next chain boundary.
async fn ensure_native_snapshot(
    network: &Network,
    peer: PeerId,
    state: &crate::VerifiedState,
    directory: &Path,
    verifier: &mut crate::verifier_session::Session,
    artifacts: &Path,
    data_directory: &Path,
) -> Result<serde_json::Value> {
    let native_db = data_directory.join("NativeState");
    let existing = if native_db.exists() {
        let installed = MdbxChainContext::open_or_create(&native_db)?;
        let local_header = verifier.checked_header(installed.tip_height())?;
        ensure!(block_id(&local_header) == installed.tip_hash()
            && installed.get_header_from_store(installed.tip_height())? == Some(local_header),
            "installed State differs from the accepted mobile chain");
        if installed.tip_height() == 0 { None } else {
            Some(serde_json::json!({"height":installed.tip_height(),
                "block_hash":hex::encode(installed.tip_hash()),
                "state_root":hex::encode(local_header.state_root)}))
        }
    } else { None };
    let mut source = peer;
    let mut selected_height = 0;
    let mut verified = None;
    let mut failure = None;
    let mut candidates = vec![peer];
    for candidate in network.peers.borrow().iter().copied() {
        if !candidates.contains(&candidate) && candidates.len() < 4 { candidates.push(candidate); }
    }
    for candidate in candidates {
        match network.verified_manifest(candidate).await {
            Ok(plan) if plan.clone().into_arc().tip_height > 0
                && plan.clone().into_arc().tip_height <= state.height() => {
                let height = plan.clone().into_arc().tip_height;
                // Do not let the first stale peer pin NFT inventory behind a
                // newer available snapshot. Proof validation still follows.
                if height > selected_height {
                    selected_height = height;
                    source = candidate;
                    verified = Some(plan);
                }
            }
            Ok(_) => failure = Some(anyhow::anyhow!("snapshot is genesis or ahead of the independently accepted proof")),
            Err(error) => failure = Some(error),
        }
    }
    let verified = match verified {
        Some(verified) => verified,
        None => {
            let issue = failure.unwrap_or_else(||anyhow::anyhow!("no snapshot peer available"));
            if let Some(mut installed) = existing {
                installed["sync_issue"] = serde_json::json!(issue.to_string());
                return Ok(installed);
            }
            return Err(issue);
        },
    };
    let plan = verified.into_arc();
    ensure!(plan.tip_height <= state.height(), "peer snapshot is newer than the accepted proof");
    if let Some(installed) = existing.as_ref() {
        if installed["height"].as_u64().is_some_and(|height| height >= plan.tip_height) {
            if installed["height"].as_u64() == Some(plan.tip_height) {
                let tip_hash = hex::encode(plan.tip_hash);
                let state_root = hex::encode(plan.state_root);
                ensure!(installed["block_hash"].as_str() == Some(tip_hash.as_str())
                    && installed["state_root"].as_str() == Some(state_root.as_str()),
                    "installed State disagrees with the advertised snapshot");
            }
            return Ok(installed.clone());
        }
    }
    let (native_verified, native_bundle, _temporary, snapshot_verifier) = if plan.tip_height == state.height() {
        (state.clone(), directory.to_path_buf(), None, None)
    } else {
        let temp = tempfile::Builder::new().prefix(".native-proof-").tempdir_in(data_directory)?;
        let snapshot_bundle = temp.path().join("candidate");
        let boundary = noid_p2p::object_protocol::ChainPoint::new(plan.tip_height, plan.tip_hash);
        fetch_bundle(network, source, boundary, &snapshot_bundle, verifier, Some(directory)).await?;
        // A proof below the accepted tip cannot be fed to the monotonic
        // verifier session. Verify it independently with a fresh verifier.
        let mut independent = crate::Verifier::open(artifacts, crate::MatrixMode::Streaming)?;
        let snapshot_verified = independent.verify_bundle(&snapshot_bundle)?;
        (snapshot_verified, snapshot_bundle, Some(temp), Some(independent))
    };
    ensure!(native_verified.height() == plan.tip_height
        && native_verified.block_hash() == hex::encode(plan.tip_hash)
        && native_verified.state_root() == hex::encode(plan.state_root),
        "snapshot proof and peer manifest disagree");
    let header = if let Some(independent) = &snapshot_verifier {
        independent.checked_header(plan.tip_height)?
    } else { verifier.checked_header(plan.tip_height)? };
    if !crate::mobile_state::installed_at(&native_db, &plan)? {
        let anchor_height = noid_chain::consensus::epoch_anchor::tx_epoch_anchor_height_for_child(header.height);
        let anchor = if let Some(independent) = &snapshot_verifier {
            independent.checked_header(anchor_height)?
        } else { verifier.checked_header(anchor_height)? };
        let staging_dir = data_directory.join("NativeStaging");
        fs::create_dir_all(&staging_dir)?;
        let staged = stage_state(network, source, &plan, header, &staging_dir).await?;
        crate::mobile_state::install(&native_verified, header, anchor, &native_bundle, &plan,
            &staged, &native_db)?;
    }
    Ok(serde_json::json!({
        "height": plan.tip_height, "block_hash": hex::encode(plan.tip_hash),
        "state_root": hex::encode(plan.state_root)
    }))
}

/// A peer's busy hint is untrusted. Cap it so a hostile or confused peer
/// cannot park the foreground verifier for minutes; the callers' bounded
/// retry loops then fail over to the next candidate.
fn peer_retry_delay(retry_after_ms: u64) -> Duration {
    Duration::from_millis(retry_after_ms.clamp(50, 5_000))
}

const MAX_OVERLAP_PROBES: u32 = 64;
/// Whether `peer` serves exactly our accepted header at `height`.
async fn peer_header_matches(
    network: &Network,
    peer: PeerId,
    accepted: &mut File,
    height: u64,
) -> Result<bool> {
    let remote = network.headers(peer, height, 1).await?;
    ensure!(remote.records.len() == 1, "incomplete fork overlap probe");
    let saved = crate::headers::read_header(accepted, height)?;
    Ok(remote.records[0].header.to_bytes() == saved.to_bytes())
}

/// Number of leading accepted headers (heights `0..n`) that `peer` serves
/// byte-for-byte, searching at most `limit` headers. Returns 0 when the peer
/// shares nothing usable or the probe budget is exhausted, which falls back
/// to a complete candidate download. Never returns more than `limit`.
async fn shared_header_prefix(
    network: &Network,
    peer: PeerId,
    accepted: &mut File,
    limit: u64,
) -> Result<u64> {
    if limit == 0 {
        return Ok(0);
    }
    let mut probes = 0u32;
    let top = limit - 1;
    probes += 1;
    if peer_header_matches(network, peer, accepted, top).await? {
        return Ok(limit);
    }
    // Invariant: `bad` mismatches. Step back exponentially to find a match.
    let mut bad = top;
    let mut step = 1u64;
    let good = loop {
        if bad == 0 || probes >= MAX_OVERLAP_PROBES {
            return Ok(0);
        }
        let probe = bad.saturating_sub(step);
        probes += 1;
        if peer_header_matches(network, peer, accepted, probe).await? {
            break probe;
        }
        bad = probe;
        step = step.saturating_mul(2);
    };
    // Invariant: `good` matches, `bad` mismatches, good < bad.
    let (mut good, mut bad) = (good, bad);
    while bad - good > 1 {
        if probes >= MAX_OVERLAP_PROBES {
            // `good` is still a verified-shared height; reuse what is known.
            break;
        }
        let middle = good + (bad - good) / 2;
        probes += 1;
        if peer_header_matches(network, peer, accepted, middle).await? {
            good = middle;
        } else {
            bad = middle;
        }
    }
    Ok(good + 1)
}

const PEER_PENALTY_SECONDS: u64 = 30 * 60;

/// Peers whose candidate failed full verification in the last 30 minutes.
/// Only affects ordering: a penalized peer is still tried if nothing else works.
fn recent_proof_failures(data_directory: &Path) -> HashSet<String> {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    artifacts::read_bounded(&data_directory.join("peer-penalties.json"), 64 * 1024).ok()
        .and_then(|bytes| serde_json::from_slice::<BTreeMap<String, u64>>(&bytes).ok())
        .map(|saved| saved.into_iter().filter(|(_, at)| now.saturating_sub(*at) < PEER_PENALTY_SECONDS).map(|(peer, _)| peer).collect())
        .unwrap_or_default()
}

fn record_proof_failure(data_directory: &Path, peer: &PeerId) {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let path = data_directory.join("peer-penalties.json");
    let mut saved: BTreeMap<String, u64> = artifacts::read_bounded(&path, 64 * 1024).ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok()).unwrap_or_default();
    saved.retain(|_, at| now.saturating_sub(*at) < PEER_PENALTY_SECONDS);
    saved.insert(peer.to_string(), now);
    while saved.len() > 64 {
        let oldest = saved.iter().min_by_key(|(_, at)| **at).map(|(peer, _)| peer.clone());
        match oldest { Some(key) => { saved.remove(&key); } None => break }
    }
    if let Ok(bytes) = serde_json::to_vec(&saved) { let _ = fs::write(path, bytes); }
}

/// Remove leftover `candidate-*` bundles and interrupted `.receiving-*` /
/// `.native-proof-*` transfers in `data_directory`, keeping `keep`. Only
/// direct children with those exact prefixes are touched; symlinks are never
/// followed. NativeState, NativeStaging and wallet files are not affected.
fn prune_unaccepted_bundles(data_directory: &Path, keep: &Path) {
    let Ok(entries) = fs::read_dir(data_directory) else { return };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if !(name.starts_with("candidate-")
            || name.starts_with(".receiving-")
            || name.starts_with(".native-proof-"))
        {
            continue;
        }
        let path = entry.path();
        if path == keep {
            continue;
        }
        let Ok(kind) = entry.file_type() else { continue };
        if !kind.is_dir() || kind.is_symlink() {
            continue;
        }
        match fs::remove_dir_all(&path) {
            Ok(()) => eprintln!("  CLEANUP    Removed unused {name}"),
            Err(error) => eprintln!("  CLEANUP    Could not remove {name}: {error:#}"),
        }
    }
}

pub(crate) fn observed_height(artifact_directory: &Path) -> Result<u64> {
    let legacy = artifacts::pinned(artifact_directory, "legacy")?;
    let bank = legacy[legacy.len() - 32..].try_into()?;
    with_connection(
        bank,
        NetworkProfile::for_proof_bank(bank),
        |executor, mut network| {
            executor.block_on(crate::mobile_control::cancellable(async move {
                while network.peers.borrow().is_empty() {
                    tokio::time::timeout(Duration::from_secs(10), network.peers.changed())
                        .await??;
                }
                let peers = network.peers.borrow().clone();
                let mut replies = FuturesUnordered::new();
                for peer in peers.into_iter().take(2) {
                    let network = network.clone();
                    replies.push(async move { (peer, network.headers(peer, 0, 1).await) });
                }
                while let Some((peer, reply)) =
                    tokio::time::timeout(Duration::from_secs(3), replies.next()).await?
                {
                    if let Ok(reply) = reply {
                        if reply.records.first().is_some_and(|r| {
                            r.header == noid_chain::consensus::genesis::genesis_header()
                        }) {
                            if let Some(point) =
                                reply.snapshot_boundary.filter(|p| p.height < MAX_HEIGHT)
                            {
                                let tail = tokio::time::timeout(
                                    Duration::from_secs(3),
                                    network.headers_with_inventory(
                                        peer,
                                        point.height + 1,
                                        64,
                                        false,
                                    ),
                                )
                                .await;
                                let observed = tail.ok().and_then(Result::ok).and_then(|r| {
                                    r.records
                                        .into_iter()
                                        .filter(|r| {
                                            r.header.height > point.height
                                                && r.header.height <= point.height + 64
                                                && r.header.height < MAX_HEIGHT
                                        })
                                        .map(|r| r.header.height)
                                        .max()
                                });
                                return Ok(observed.unwrap_or(point.height));
                            }
                        }
                    }
                }
                anyhow::bail!("Mainnet peer is unavailable")
            }))
        },
    )
}

pub fn run(
    artifact_directory: PathBuf,
    data_directory: PathBuf,
    once: bool,
) -> Result<serde_json::Value> {
    ensure!(
        artifacts::profile().network == "mainnet",
        "run requires the mainnet build"
    );
    fs::create_dir_all(&data_directory)?;
    let started = Instant::now();
    eprintln!("\n\x1b[1;32m  PARAMO1D  ·  MAINNET\x1b[0m\n");
    eprintln!(
        "  CPU        {} automatic verification workers",
        rayon::current_num_threads()
    );
    eprintln!("  RUNTIME    Loading released verification parameters");
    let legacy = artifacts::read_bounded(&artifact_directory.join("legacy"), 4 * 1024 * 1024)?;
    let bank = legacy[legacy.len() - 32..].try_into()?;
    let profile = NetworkProfile::for_proof_bank(bank);
    eprintln!("  NETWORK    Discovering mainnet peers over device internet");
    with_connection(bank, profile, |executor, mut network| {
        let artifacts_for_snapshot = artifact_directory.clone();
        let runtime_started = Instant::now();
        crate::verifier_session::with(&artifact_directory, |verifier| {
            let runtime_load_ms = runtime_started.elapsed().as_millis();
            executor.block_on(crate::mobile_control::cancellable(async move {
        let mut round = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_millis() as u64;
        let mut previous: Option<PathBuf> = None;
        let mut accepted_height = None;
        let mut resumed = None;
        let resume_started = Instant::now();
        if let Ok(bytes) = artifacts::read_bounded(&data_directory.join("accepted.json"), 1024 * 1024) {
            if let Ok(saved) = serde_json::from_slice::<serde_json::Value>(&bytes) {
                if let Some(name) = saved["bundle"].as_str().filter(|name| name.starts_with("candidate-") && name.len()<128 && !name.contains('/') && !name.contains('\\')) {
                    let directory=data_directory.join(name);
                    // Check the stored header work first. A newer recursive
                    // proof authenticates the resulting State and history.
                    if let Ok((height,state))=verifier.prepare_resume(&directory) {
                        accepted_height=Some(height);
                        resumed=state.map(|state|serde_json::json!({"transport":"direct-p2p","bundle":name,"verified":state,"reused_boundary":true}));
                        previous=Some(directory);
                    }
                }
            }
        }
        let resume_ms = resume_started.elapsed().as_millis();
        // iOS: earlier builds kept rejected candidates and interrupted transfers.
        // Only prune when the accepted record names an existing bundle, so a
        // damaged record never deletes the only usable saved proof.
        if let Some(keep) = previous.as_ref().filter(|directory| directory.is_dir()) {
            prune_unaccepted_bundles(&data_directory, keep);
        }
        let mut initial_sync_ms = None;
        loop {
            let discovery_started = Instant::now();
            let mut candidates = discover(&mut network).await?;
            let discovery_ms = discovery_started.elapsed().as_millis();
            // iOS: try peers whose candidate recently failed proof verification last.
            let penalized = recent_proof_failures(&data_directory);
            candidates.sort_by_key(|(peer, point)| (penalized.contains(&peer.to_string()), std::cmp::Reverse(point.height)));
            if accepted_height.is_some_and(|height| candidates.iter().all(|(_, point)| point.height <= height)) {
                // Returning the saved State itself requires its full proof.
                if resumed.is_none() {
                    if let Some(directory) = previous.as_ref() {
                        match verifier.verify_bundle(directory) {
                            Ok(state) => resumed=Some(serde_json::json!({"transport":"direct-p2p","bundle":directory.file_name().and_then(|v|v.to_str()),"verified":state,"reused_boundary":true})),
                            Err(error) => {
                                verifier.discard_resume_headers();
                                previous=None; accepted_height=None;
                                eprintln!("  RECOVER    Stored proof: {error:#}");
                                continue;
                            }
                        }
                    }
                }
                if once {
                    let mut result = resumed.context("accepted boundary unavailable")?;
                    // iOS: keep asset State current with the reused boundary.
                    if let (Some(directory), Some((peer, _))) = (previous.as_ref(), candidates.first()) {
                        let state = verifier.verify_bundle(directory)?;
                        match ensure_native_state(&network, *peer, &state, directory, verifier, &artifacts_for_snapshot, &data_directory).await {
                            Ok(installed) => result["native_state"] = installed,
                            Err(error) => {
                                eprintln!("  NATIVE     State not installed: {error:#}");
                                result["native_state_error"] = serde_json::json!(error.to_string());
                            }
                        }
                    }
                    result["runtime_load_ms"] = serde_json::json!(runtime_load_ms);
                    result["resume_ms"] = serde_json::json!(resume_ms);
                    result["discovery_ms"] = serde_json::json!(discovery_ms);
                    result["transfer_ms"] = serde_json::json!(0);
                    return Ok(result);
                }
                tokio::time::sleep(Duration::from_secs(5)).await;
                continue;
            }
            let mut accepted = None;
            let mut last_failure = None;
            let mut transfer_ms = 0;
            let update_started = Instant::now();
            for (peer, boundary) in candidates {
                round += 1;
                let output = data_directory.join(format!("candidate-{round}-{}", boundary.height));
                if accepted_height.is_some_and(|height| boundary.height <= height) { continue; }
                crate::mobile_control::verifying();
                let transfer_started = Instant::now();
                let fetched = fetch_bundle(&network, peer, boundary, &output, &verifier, previous.as_deref()).await;
                transfer_ms += transfer_started.elapsed().as_millis();
                match fetched {
                    Ok(()) => {
                        eprintln!("  VERIFY     Header work, fork certificate and recursive State proof");
                        let checked = verifier.verify_bundle(&output);
                        match checked {
                            Ok(state) => { accepted = Some((state, output, peer)); break; }
                            Err(error) => {
                                eprintln!("  RETRY      Candidate verification: {error:#}");
                                last_failure = Some(format!("proof: {error:#}"));
                                record_proof_failure(&data_directory, &peer);
                                // iOS: a rejected candidate is never reused. Remove it now:
                                // each holds the full header history and would fill storage.
                                if let Err(cleanup) = fs::remove_dir_all(&output) {
                                    eprintln!("  CLEANUP    Rejected candidate: {cleanup:#}");
                                }
                            }
                        }
                    }
                    Err(error) => {
                        eprintln!("  RETRY      Peer transfer: {error:#}");
                        last_failure = Some(format!("transfer: {error:#}"));
                    }
                }
            }
            // A damaged saved bundle must not pin an unusable header hint.
            // Authenticate the old proof before retaining its floor after a
            // failed update. Only the provisional cold-start hint is cleared.
            if accepted.is_none() && verifier.discard_resume_headers() {
                let old_is_valid = previous.as_ref().is_some_and(|directory|verifier.verify_bundle(directory).is_ok());
                if !old_is_valid {
                    previous=None; accepted_height=None; resumed=None;
                    continue;
                }
            }
            let (state, directory, peer) = accepted.ok_or_else(|| {
                let reason = last_failure.unwrap_or_else(|| "no newer proof source was usable".into());
                let reason: String = reason.replace('\r', " ").replace('\n', " ").chars().take(150).collect();
                anyhow::anyhow!("No mainnet candidate passed verification. Last failure: {reason}")
            })?;
            let native_state = ensure_native_state(&network, peer, &state, &directory, verifier, &artifacts_for_snapshot, &data_directory).await;
            let (native_state, native_state_error) = match native_state {
                Ok(installed) => (Some(installed), None),
                Err(error) => {
                    eprintln!("  NATIVE     State not installed: {error:#}");
                    (None, Some(error.to_string()))
                }
            };
            eprintln!("\n\x1b[1;32m  SYNCED     MAINNET · BLOCK {}\x1b[0m", state.height());
            eprintln!("  STATE      {}", state.state_root());
            if initial_sync_ms.is_none() { eprintln!("  TOTAL      {:.2} seconds from process startup\n", started.elapsed().as_secs_f64()); }
            else { eprintln!("  UPDATE     {:.2} seconds\n", update_started.elapsed().as_secs_f64()); }
            let startup_ms = *initial_sync_ms.get_or_insert_with(|| started.elapsed().as_millis());
            let peak = peak_memory_kib();
            if let Some(kib) = peak { eprintln!("  RAM        {:.1} MiB peak", kib as f64/1024.0); }
            let result = serde_json::json!({"transport":"direct-p2p","bundle":directory.file_name().and_then(|v|v.to_str()),"startup_ms":startup_ms,"update_ms":update_started.elapsed().as_millis(),"peak_rss_kib":peak,"verified":state,
                "native_state":native_state,"native_state_error":native_state_error,
                "runtime_load_ms":runtime_load_ms,"resume_ms":resume_ms,"discovery_ms":discovery_ms,"transfer_ms":transfer_ms});
            let mut record=tempfile::NamedTempFile::new_in(&data_directory)?;
            record.write_all(&serde_json::to_vec_pretty(&result)?)?;
            record.as_file().sync_all()?;
            record.persist(data_directory.join("accepted.json")).map_err(|e|e.error)?;
            if once {
                if let Some(old)=previous.filter(|old|old!=&directory) { fs::remove_dir_all(old)?; }
                return Ok(result);
            }
            accepted_height = Some(state.height());
            if let Some(old) = previous.replace(directory) { fs::remove_dir_all(old)?; }
            tokio::time::sleep(Duration::from_secs(5)).await;
        }
    }))
        })
    })
}
