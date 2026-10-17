import Testing

@MainActor
@Suite("GammaDimmer: Umrechnung")
struct GammaDimmerTests {
    @Test("100 % lässt die Kurve unverändert, 0 % bleibt über der Untergrenze")
    func factorRange() {
        #expect(GammaDimmer.factor(forPercent: 100) == 1)
        #expect(GammaDimmer.factor(forPercent: 0) == GammaDimmer.minimumFactor)
        #expect(GammaDimmer.factor(forPercent: -5) == GammaDimmer.minimumFactor)
        #expect(GammaDimmer.factor(forPercent: 150) == 1)
        #expect(abs(GammaDimmer.factor(forPercent: 50) - 0.55) < 0.0001)
    }
}
