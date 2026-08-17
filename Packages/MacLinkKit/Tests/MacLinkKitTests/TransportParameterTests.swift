import Network
import XCTest
@testable import MacLinkKit

/// These assertions are the product requirement in executable form: the link reaches a Mac that is
/// beside you — over a shared network or a direct AWDL link — and never over the internet.
final class TransportParameterTests: XCTestCase {

    func testPeerToPeerIsEnabledSoNoSharedNetworkIsNeeded() {
        XCTAssertTrue(LinkParameters.tcp().includePeerToPeer)
        XCTAssertTrue(LinkParameters.discovery(peerToPeer: true).includePeerToPeer)
    }

    /// Discovery deliberately also runs a non-peer-to-peer browser: a peer-to-peer browser does not
    /// reliably return ordinary Wi-Fi results, and finds nothing at all in the Simulator.
    func testDiscoveryAlsoCoversPlainInfrastructure() {
        XCTAssertFalse(LinkParameters.discovery(peerToPeer: false).includePeerToPeer)
    }

    func testCellularIsProhibitedOnEveryPath() {
        XCTAssertTrue(LinkParameters.tcp().prohibitedInterfaceTypes?.contains(.cellular) ?? false)
        for peerToPeer in [true, false] {
            XCTAssertTrue(
                LinkParameters.discovery(peerToPeer: peerToPeer).prohibitedInterfaceTypes?.contains(.cellular) ?? false,
                "cellular must stay prohibited (peerToPeer: \(peerToPeer))"
            )
        }
    }

    func testNagleIsDisabledForPointerLatency() throws {
        let parameters = LinkParameters.tcp()
        let tcpOptions = try XCTUnwrap(parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)
        // Nagle would hold small pointer packets back by tens of milliseconds, which is visible as
        // cursor lag.
        XCTAssertTrue(tcpOptions.noDelay)
    }
}
