import Foundation
import SwiftUI

enum EmailDurationBucket: CaseIterable, Identifiable {
    case lessThan24Hours
    case between1And7Days
    case between1And4Weeks
    case between1And3Months
    case moreThan3Months
    
    var id: Self { self }
    
    var timeInterval: TimeInterval {
        switch self {
        case .lessThan24Hours: return 24 * 60 * 60 // 1 day
        case .between1And7Days: return 7 * 24 * 60 * 60 // 1 week
        case .between1And4Weeks: return 4 * 7 * 24 * 60 * 60 // 4 weeks (1 month)
        case .between1And3Months: return 3 * 30 * 24 * 60 * 60 // 3 months
        case .moreThan3Months: return .greatestFiniteMagnitude
        }
    }
    
    var color: Color {
        switch self {
        case .lessThan24Hours: return .green // Recent emails (< 24 hours)
        case .between1And7Days: return .yellow // Emails older than a day but less than a week
        case .between1And4Weeks: return .orange // Emails older than a week but less than a month
        case .between1And3Months: return .brown // Old emails (1-3 months)
        case .moreThan3Months: return .gray // Very old emails (> 3 months)
        }
    }
    
    var displayName: String {
        switch self {
        case .lessThan24Hours: return "< 1d"
        case .between1And7Days: return "1-7d"
        case .between1And4Weeks: return "1-4w"
        case .between1And3Months: return "1-3mo"
        case .moreThan3Months: return "> 3mo"
        }
    }
    
    static func bucket(for receivedAt: Date, relativeTo now: Date = Date()) -> EmailDurationBucket {
        let interval = now.timeIntervalSince(receivedAt)
        
        for bucket in Self.allCases {
            if interval < bucket.timeInterval {
                return bucket
            }
        }
        
        return .moreThan3Months
    }
}