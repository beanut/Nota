import Foundation
import SwiftData

/// Seeds the library with sample folders and notes the first time the staging app launches.
/// Production builds never seed (see `AppEnvironment.seedsSampleData`).
@MainActor
enum SampleData {
    private static let seededKey = "didSeedSampleLibrary"

    static func seedIfNeeded(in context: ModelContext) {
        guard AppEnvironment.current.seedsSampleData else { return }
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        defer { UserDefaults.standard.set(true, forKey: seededKey) }

        let existing = (try? context.fetchCount(FetchDescriptor<Note>())) ?? 0
        guard existing == 0 else { return }
        seed(in: context)
    }

    static func seed(in context: ModelContext) {
        let courses = Folder(name: "Courses", color: .blue, sortIndex: 0)
        let work = Folder(name: "Work", color: .teal, sortIndex: 1)
        let personal = Folder(name: "Personal", color: .orange, sortIndex: 2)
        [courses, work, personal].forEach(context.insert)

        func daysAgo(_ days: Int, hour: Int = 10) -> Date {
            let calendar = Calendar.current
            let day = calendar.date(byAdding: .day, value: -days, to: .now) ?? .now
            return calendar.date(bySettingHour: min(hour, calendar.component(.hour, from: .now)),
                                 minute: 0, second: 0, of: day) ?? day
        }

        let featured: [Note] = [
            Note(title: "Physics — Lecture 7", pageCount: 12, modifiedAt: daysAgo(0), paper: .lined,
                 tint: .indigo, isFavorite: true, folder: courses),
            Note(title: "Sketchbook: Interiors", pageCount: 34, modifiedAt: daysAgo(1), paper: .dotted,
                 tint: .teal, isFavorite: true, folder: personal),
            Note(title: "Project Kestrel", pageCount: 8, modifiedAt: daysAgo(2), paper: .grid,
                 tint: .indigo, isShared: true, folder: work),
            Note(title: "Reading Journal", pageCount: 21, modifiedAt: daysAgo(9), paper: .lined,
                 tint: .rust, folder: personal),
            Note(title: "Design Sync", pageCount: 3, modifiedAt: daysAgo(12), paper: .plain,
                 tint: .graphite, isShared: true, folder: work),
            Note(title: "Spanish Vocabulary", pageCount: 46, modifiedAt: daysAgo(18), paper: .lined,
                 tint: .indigo, isFavorite: true, folder: courses),
            Note(title: "Trip Planning: Lisbon", pageCount: 9, modifiedAt: daysAgo(23), paper: .dotted,
                 tint: .rust, isShared: true, folder: personal),
            Note(title: "Quick Notes", pageCount: 5, modifiedAt: daysAgo(30), paper: .plain,
                 tint: .violet, folder: personal),
        ]

        let courseTitles = ["Calculus II — Problem Set 4", "Organic Chemistry", "Physics — Lecture 6",
                            "Physics — Lecture 5", "Linear Algebra Notes", "History of Architecture",
                            "Statistics Cheat Sheet", "Spanish Grammar", "Lab Report Draft",
                            "Physics Syllabus", "Exam Review: Mechanics", "Philosophy Reading"]
        let workTitles = ["Kestrel Roadmap", "Weekly 1:1s", "Onboarding Flow Sketches", "Q4 Planning",
                          "Brand Workshop", "Interview Notes", "Kestrel Architecture", "Retro: Sprint 21",
                          "Pricing Research", "Customer Calls", "Design Critique", "Launch Checklist",
                          "Wireframes v2", "Team Offsite", "Hiring Plan", "Board Prep", "API Contract Review"]
        let personalTitles = ["Recipes", "Garden Layout", "Budget 2026", "Book List", "Workout Log"]

        let tints = NoteTint.allCases
        let papers = PaperStyle.allCases
        var archive: [Note] = []
        for (folder, titles, offset) in [(courses, courseTitles, 0), (work, workTitles, 3), (personal, personalTitles, 7)] {
            for (i, title) in titles.enumerated() {
                let isPDF = (i + offset) % 5 == 4
                archive.append(Note(title: title,
                                    pageCount: isPDF ? 2 + (i * 7) % 30 : 1 + (i * 5) % 24,
                                    modifiedAt: daysAgo(34 + i * 4 + offset),
                                    paper: papers[(i + offset) % papers.count],
                                    tint: tints[(i + offset) % tints.count],
                                    kind: isPDF ? .pdf : .notebook,
                                    isFavorite: i % 7 == 2,
                                    isShared: i % 6 == 3,
                                    folder: folder))
            }
        }

        (featured + archive).forEach(context.insert)
        try? context.save()
    }
}
