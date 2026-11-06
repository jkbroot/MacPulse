import XCTest
@testable import MacPulse

final class NettopParserTests: XCTestCase {
    private func run(_ blocks: [String]) -> NettopCollector {
        let c = NettopCollector()
        for b in blocks { c.ingestForTesting(b) }
        return c
    }

    func testCountsDeltaOfConnection() {
        let c = run([
            ",bytes_in,bytes_out,\ncurl.100,0,0,\ntcp4 10.0.0.2:5000<->1.2.3.4:443,1000,10,\n",
            ",bytes_in,bytes_out,\ncurl.100,0,0,\ntcp4 10.0.0.2:5000<->1.2.3.4:443,5000,30,\n",
            ",bytes_in,bytes_out,\n",
        ])
        let d = c.drain()
        XCTAssertEqual(d.perPid[100]?.inB, 4000)   // first sample is baseline only
        XCTAssertEqual(d.perPid[100]?.outB, 20)
        XCTAssertEqual(d.perDest.keys.first?.host, "1.2.3.4")
    }

    func testMulticastSocketsIgnored() {
        let c = run([
            ",bytes_in,bytes_out,\nBrave.7,0,0,\nudp6 *.5353<->*.*,100,1,\nudp6 *.5353<->*.*,50000000,1,\n",
            ",bytes_in,bytes_out,\nBrave.7,0,0,\nudp6 *.5353<->*.*,0,1,\nudp6 *.5353<->*.*,90000000,1,\n",
            ",bytes_in,bytes_out,\n",
        ])
        XCTAssertNil(c.drain().perPid[7])
    }

    /// A local program can name itself anything; it must not be able to crash the monitor or forge rows.
    func testHostileProcessNamesAndHugeCounters() {
        let max = String(UInt64.max)
        let c = run([
            ",bytes_in,bytes_out,\nevil,a<->b.66,0,0,\ntcp4 1.1.1.1:1<->2.2.2.2:2,\(max),\(max),\n",
            ",bytes_in,bytes_out,\ntcp4 x<->9.9.9.9:1,1,1,\nevil.9,0,0,\ntcp4 1.1.1.1:1<->2.2.2.2:2,\(max),\(max),\n"
                + "tcp4 1.1.1.1:2<->2.2.2.2:2,1125899906842623,1,\ntcp4 1.1.1.1:3<->2.2.2.2:2,1125899906842623,1,\n",
            ",bytes_in,bytes_out,\n",
        ])
        let d = c.drain()   // must not trap
        XCTAssertNil(d.perDest.keys.first { $0.host == "9.9.9.9" })            // row before any process ignored
        XCTAssertLessThan(d.perPid[9]?.inB ?? 0, NettopCollector.maxCounter * 4) // absurd values rejected
    }

    func testIPv6HostParsing() {
        XCTAssertEqual(NettopCollector.host(from: "2a00:1450::200e.443", v6: true), "2a00:1450::200e")
        XCTAssertEqual(NettopCollector.host(from: "fe80::1%en0.5353", v6: true), "fe80::1")
        XCTAssertEqual(NettopCollector.host(from: "17.1.2.3:443", v6: false), "17.1.2.3")
    }
}

final class ExportAndFormattingTests: XCTestCase {
    override func setUp() { L10n.apply(.en) }

    func testArabicIsolatesNumbers() {
        L10n.apply(.ar); defer { L10n.apply(.en) }
        XCTAssertEqual(Fmt.bytes(UInt64(2048)), "\u{2066}2 KB\u{2069}")
        XCTAssertTrue(Fmt.updown("1 MB", "2 KB").hasPrefix("\u{2066}↓"))
    }
    func testCSVFormulaInjectionNeutralised() {
        XCTAssertEqual(CSV.cell("=HYPERLINK(\"http://x\")"), "\"'=HYPERLINK(\"\"http://x\"\")\"")
        XCTAssertEqual(CSV.cell("+1"), "\"'+1\"")
        XCTAssertEqual(CSV.cell("@SUM(A1)"), "\"'@SUM(A1)\"")
        XCTAssertEqual(CSV.cell("a,b\nc"), "\"a,b c\"")
        XCTAssertEqual(CSV.cell("example.com"), "\"example.com\"")
    }

    func testClampingConversionsNeverTrap() {
        XCTAssertEqual(UInt64(clamping: Double.nan), 0)
        XCTAssertEqual(UInt64(clamping: -5), 0)
        XCTAssertEqual(UInt64(clamping: .infinity), 0)
        XCTAssertEqual(UInt64(clamping: 1e30), .max)
        XCTAssertEqual(Int(clamping: 1e30), .max)
        XCTAssertEqual(Fmt.bytes(Double.nan), "0 B")
    }

    func testDownsampleKeepsPeaks() {
        let now = Date()
        let pts = (0..<450).map { LivePoint(t: now.addingTimeInterval(Double($0)), cpu: 0.1, mem: 0.5, power: 5, netIn: $0 == 200 ? 1e9 : 10, netOut: 1) }
        let d = Monitor.downsample(pts, to: 90)
        XCTAssertEqual(d.count, 90)
        XCTAssertEqual(d.map(\.netIn).max(), 1e9)
    }
}
