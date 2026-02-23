import SwiftUI

struct EmailDurationIndicatorView: View {
    let bucketCounts: [EmailDurationBucket: Int]
    
    private var totalEmails: Int {
        bucketCounts.values.reduce(0, +)
    }
    
    private var bucketPercentages: [EmailDurationBucket: Double] {
        guard totalEmails > 0 else {
            return bucketCounts.mapValues { _ in 0.0 }
        }
        
        return bucketCounts.mapValues { count in
            Double(count) / Double(totalEmails)
        }
    }
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(EmailDurationBucket.allCases) { bucket in
                Rectangle()
                    .fill(bucket.color.opacity(0.8))
                    .frame(width: bucketWidth(for: bucket))
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                    )
            }
        }
        .frame(height: 16)
        .background(Color.secondary.opacity(0.2))
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
        )
        .help(helpText)
    }
    
    private func bucketWidth(for bucket: EmailDurationBucket) -> CGFloat? {
        guard totalEmails > 0 else { return nil }
        let percentage = bucketPercentages[bucket] ?? 0.0
        return percentage * 120 // Total width of the indicator
    }
    
    private var helpText: String {
        guard totalEmails > 0 else {
            return "No emails to display"
        }
        
        var text = "Email distribution by duration:\n"
        let sortedBuckets = EmailDurationBucket.allCases.sorted { bucket1, bucket2 in
            bucket1.timeInterval < bucket2.timeInterval
        }
        
        for bucket in sortedBuckets {
            let count = bucketCounts[bucket] ?? 0
            if count > 0 {
                let percentage = Int(round((Double(count) / Double(totalEmails)) * 100))
                text += "\(bucket.displayName): \(count) emails (\(percentage)%)\n"
            }
        }
        
        return text
    }
}

struct EmailDurationIndicatorView_Previews: PreviewProvider {
    static var previews: some View {
        let now = Date()
        var counts: [EmailDurationBucket: Int] = [:]
        for bucket in EmailDurationBucket.allCases {
            counts[bucket] = 0
        }
        
        // Sample data
        counts[.lessThan24Hours] = 5
        counts[.between1And7Days] = 3
        counts[.between1And4Weeks] = 2
        counts[.between1And3Months] = 4
        counts[.moreThan3Months] = 1
        
        return EmailDurationIndicatorView(bucketCounts: counts)
            .padding()
            .previewLayout(.sizeThatFits)
    }
}