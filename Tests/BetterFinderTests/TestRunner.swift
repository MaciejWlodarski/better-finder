import Foundation

struct RegressionFailure: LocalizedError, CustomStringConvertible {
    let description: String
    var errorDescription: String? { description }
}

func expect(_ condition: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) throws {
    if !condition() { throw RegressionFailure(description: "Assertion failed at \(file):\(line)") }
}

@main struct TestRunner {
    @MainActor static func main() async {
        do {
            try CommandColdStartRegressionTests().runBeforeApplicationInitialization()
            try await FolderSizeLifecycleRegressionTests().runAll()
            try await DirectoryNavigationRegressionTests().runAll()
            let tests = NavigationTests()
            try await tests.testDirectoryShowsFilesBeforeTagMetadataCompletes()
            print("PASS directory listing precedes asynchronous tag metadata")
            try tests.testShiftSelectionKeepsAnchorAndCanShrink()
            print("PASS stable Shift selection and shrink")
            try tests.testArrowFromNoSelectionAndSelectAll()
            print("PASS arrow boundaries and Select All")
            try tests.testHiddenFilesRefreshAndDescendingOrder()
            print("PASS hidden files and descending sort")
            try await tests.testClearingSearchRejectsPendingResults()
            print("PASS cancelled search cannot replace directory")
            try await tests.testReloadRerunsActiveSearchAfterDeletion()
            print("PASS active search refresh after deletion")
            try await tests.testNavigationWithLocalQueryRefreshesBrowsingSnapshot()
            print("PASS navigating with local search keeps the correct folder snapshot")
            try tests.testScopeInvalidationUsesDirectoryBoundaries()
            print("PASS scope invalidation respects path boundaries")
            try tests.testNewTabIncludesInheritedHiddenFiles()
            print("PASS new tabs inherit visible hidden files")
            try await FileDropLifecycleRegressionTests().runAll()
            try await tests.testDropLoadsAllFileProvidersAsOneDeduplicatedBatch()
            print("PASS drop collects every URL before starting a batch")
            try await tests.testSearchCommitPublishesUpdatedMetadataAndRevision()
            print("PASS same-path search updates publish fresh metadata to the inspector")
            try await tests.testNavigationCannotSelectOldSearchResults()
            try tests.testViewModeSwitchRemovesInvisibleOutlineSelection()
            try tests.testVisibleExpandedAndAncestorColumnChangesInvalidate()
            try tests.testAnalysisSelectionIsBoundedToModeAndRoot()
            try await ThumbnailLifecycleRegressionTests().runAll()
            try await tests.testThumbnailInvalidationRejectsLateGeneration()
            try await tests.testFolderSizesExposePartialAndCountDeepFiles()
            try await tests.testExternalChangeInvalidatesFolderSizeWithoutVisiblePane()
            try tests.testColumnSortUsesPaneRulesAndUnknownSizesSortLast()
            try tests.testInvalidSearchClearsActionTargetsAndShowsDiagnostic()
            try await SearchQuerySafetyRegressionTests.runAll()
            try SearchMatchingPrecisionRegressionTests.runAll()
            try await SearchIndexRegressionTests.runAll()
            print("Search/index regression suite passed")
            try await SavedSearchRegressionTests().runAll()
            try await SessionRestorationRegressionTests().runAll()
            try await QuickLookOwnershipRegressionTests().runAll()
            try GUIPresentationRegressionTests().runAll()
            try AnalysisViewBindingRegressionTests().runAll()
            try await DiskAnalysisRegressionTests().runAll()
            print("Disk analysis/terminal regression suite passed")
            let previewChecks = try await InspectorPreviewRegressionTests.runAll()
            print("\(previewChecks) inspector preview checks passed")
            let fileOperationChecks = try await FileOperationSafetyTests.runAll()
            print("\(fileOperationChecks) file-operation safety checks passed")
            print("20 navigation/cache regression checks passed")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
