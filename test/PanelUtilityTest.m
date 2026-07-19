classdef PanelUtilityTest < matlab.unittest.TestCase
    methods (Test)
        function coveragePercentHandlesApplicableAndEmptyMetrics(testCase)
            testCase.verifyEqual(matlabcopilot.Panel.coveragePercent([5 10]), 50);
            testCase.verifyEqual(matlabcopilot.Panel.coveragePercent([1 3]), 33.3);
            testCase.verifyEqual(matlabcopilot.Panel.coveragePercent([]), 0);
            testCase.verifyEqual(matlabcopilot.Panel.coveragePercent([0 0]), 0);
        end

        function deterministicReportsBecomeRecorderEvidence(testCase)
            standards = matlabcopilot.Panel.projectEvidenceEntry(struct( ...
                'type', "standards_report", 'model', 'demo', 'errors', 1, 'warns', 2));
            testCase.verifyEqual(string(standards.source), "deterministic-verification");
            testCase.verifyEqual(string(standards.status), "failed");
            testCase.verifyEqual(standards.metrics.errors, 1);

            tests = matlabcopilot.Panel.projectEvidenceEntry(struct( ...
                'type', "testrun_report", 'passed', 4, 'failed', 0));
            testCase.verifyEqual(string(tests.status), "passed");

            coverage = matlabcopilot.Panel.projectEvidenceEntry(struct( ...
                'type', "coverage_report", 'decision', [8 10], ...
                'condition', [4 5], 'mcdc', [3 5], 'gaps', {{struct('path', 'demo/Gain')}}));
            testCase.verifyEqual(string(coverage.status), "failed");
            testCase.verifyEqual(coverage.metrics.decisionPercent, 80);
            testCase.verifyEqual(coverage.metrics.gaps, 1);

            req = matlabcopilot.Panel.projectEvidenceEntry(struct( ...
                'type', "req_matrix", 'total', 2, 'covered', 1, ...
                'rows', {{struct('id', 'REQ-1'), struct('id', 'REQ-2')}}));
            testCase.verifyEqual(string(req.requirements), ["REQ-1", "REQ-2"]);
            testCase.verifyEmpty(matlabcopilot.Panel.projectEvidenceEntry(struct('type', "status")));
        end
    end
end
