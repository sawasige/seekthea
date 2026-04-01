//
//  Item.swift
//  Seekthea
//
//  Created by SAWADA Shigeru on 2026/04/01.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
