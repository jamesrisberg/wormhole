//
//  wormholeTests.swift
//  wormholeTests
//
//  Created by James Risberg on 2/8/25.
//

import Testing
@testable import wormhole

struct wormholeTests {

    @Test func appModuleLoads() {
        #expect(PortalDefinition.wormhole.isWormhole)
    }

}
