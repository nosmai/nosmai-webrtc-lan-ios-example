import Foundation
import MultipeerConnectivity

/// WebRTC needs a "signaling" channel to exchange the offer, answer and ICE
/// candidates before the peers can talk directly. WebRTC does not provide one.
///
/// To keep this sample runnable without a server, signaling goes over the local
/// network with MultipeerConnectivity: the host advertises a room, viewers find
/// it and connect. Both phones must be on the same Wi-Fi.
///
/// In a real app, replace this class with your own signaling (for example a
/// WebSocket to your backend). Nothing else in the sample depends on how the
/// messages travel. All callbacks are delivered on the main queue.
final class LocalSignaling: NSObject {
    /// Bonjour service type; must match NSBonjourServices in Info.plist.
    private static let serviceType = "nosmai-live"

    var onPeerConnected: ((MCPeerID) -> Void)?
    var onPeerDisconnected: ((MCPeerID) -> Void)?
    var onMessage: (([String: Any], MCPeerID) -> Void)?

    private let room: String
    private let isHost: Bool
    private let peerID: MCPeerID
    private let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    /// Audience: the host we have invited, so we do not invite twice.
    private var invitedHost: MCPeerID?

    init(room: String, isHost: Bool) {
        self.room = room
        self.isHost = isHost
        peerID = MCPeerID(displayName: (isHost ? "host-" : "viewer-") + UUID().uuidString.prefix(6))
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    /// Host: advertise the room. Audience: look for a host of the same room.
    func start() {
        if isHost {
            let advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: ["room": room],
                                                       serviceType: Self.serviceType)
            advertiser.delegate = self
            advertiser.startAdvertisingPeer()
            self.advertiser = advertiser
        } else {
            let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
            browser.delegate = self
            browser.startBrowsingForPeers()
            self.browser = browser
        }
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser = nil
        browser = nil
        session.disconnect()
    }

    func send(_ message: [String: Any], to peer: MCPeerID) {
        guard session.connectedPeers.contains(peer),
              let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        try? session.send(data, toPeers: [peer], with: .reliable)
    }
}

extension LocalSignaling: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                self.onPeerConnected?(peerID)
            case .notConnected:
                if self.invitedHost == peerID {
                    // Lost the host: search again so we reconnect when it returns.
                    self.invitedHost = nil
                    self.browser?.stopBrowsingForPeers()
                    self.browser?.startBrowsingForPeers()
                }
                self.onPeerDisconnected?(peerID)
            default:
                break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        DispatchQueue.main.async { self.onMessage?(message, peerID) }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String,
                 fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension LocalSignaling: MCNearbyServiceAdvertiserDelegate {
    /// Host: a viewer asked to join.
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }
}

extension LocalSignaling: MCNearbyServiceBrowserDelegate {
    /// Audience: found a host; join it if it is hosting our room.
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            guard info?["room"] == self.room, self.invitedHost == nil else { return }
            self.invitedHost = peerID
            browser.invitePeer(peerID, to: self.session, withContext: nil, timeout: 30)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
