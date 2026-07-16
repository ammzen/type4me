import AppKit
import SwiftUI

struct IssueReportSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var issueTitle = ""
    @State private var problemDescription = ""
    @State private var includeLogs = true
    @State private var reportStatus: ReportStatus?

    private let environment = IssueReportEnvironment.current

    private var canCreateReport: Bool {
        !problemDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("报告问题", "Report an Issue"))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(TF.settingsText)
                    Text(L(
                        "填写问题后，可打开预填好的 GitHub Issue，或复制完整诊断报告。",
                        "Describe the problem, then open a prefilled GitHub issue or copy the full diagnostic report."
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsTextSecondary)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(L("问题标题（可选）", "Issue title (optional)"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.settingsText)
                TextField(
                    L("例如：蓝牙耳机录音结束后没有恢复音乐音质", "Example: Bluetooth audio does not recover after recording"),
                    text: $issueTitle
                )
                .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(L("问题描述", "Problem description"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.settingsText)
                TextEditor(text: $problemDescription)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .background(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(TF.settingsTextTertiary.opacity(0.25), lineWidth: 1)
                    )
                    .frame(minHeight: 160)
                Text(L(
                    "建议写清楚：发生了什么、如何复现、你原本期待什么。",
                    "Include what happened, how to reproduce it, and what you expected."
                ))
                .font(.system(size: 10))
                .foregroundStyle(TF.settingsTextTertiary)
            }

            VStack(alignment: .leading, spacing: 7) {
                Toggle(isOn: $includeLogs) {
                    Text(L("包含最近的诊断日志", "Include recent diagnostic logs"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TF.settingsText)
                }
                .toggleStyle(.checkbox)

                Text(L(
                    "日志会自动隐藏 API Key、Token、邮箱、用户目录和输入框文本，但仍建议在 GitHub 提交前快速检查。",
                    "API keys, tokens, email addresses, home paths, and detected input text are redacted automatically. Please still review before submitting."
                ))
                .font(.system(size: 10))
                .foregroundStyle(TF.settingsTextTertiary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let reportStatus {
                Label(
                    reportStatus.message,
                    systemImage: reportStatus.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                )
                    .font(.system(size: 11))
                    .foregroundStyle(reportStatus.isError ? .orange : .green)
            }

            HStack(spacing: 10) {
                Button(L("取消", "Cancel")) {
                    dismiss()
                }

                Spacer()

                Button {
                    copyFullReport()
                } label: {
                    Label(L("复制完整报告", "Copy Full Report"), systemImage: "doc.on.doc")
                }
                .disabled(!canCreateReport)

                Button {
                    openGitHubIssue()
                } label: {
                    Label(L("打开 GitHub 提交", "Open GitHub Issue"), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canCreateReport)
            }
        }
        .padding(24)
        .frame(width: 590, height: 520)
        .background(TF.settingsBg)
    }

    private func reportInputs() -> (title: String, log: String, report: String) {
        let log = includeLogs
            ? DebugFileLogger.reportContents(maxCharacters: IssueReportService.maximumReportLogCharacters)
            : ""
        let title = IssueReportService.suggestedTitle(
            customTitle: issueTitle,
            description: problemDescription
        )
        let report = IssueReportService.fullReport(
            description: problemDescription,
            environment: environment,
            includeLogs: includeLogs,
            logText: log
        )
        return (title, log, report)
    }

    private func copyFullReport() {
        let inputs = reportInputs()
        copyToPasteboard(inputs.report)
        reportStatus = ReportStatus(
            message: L("完整报告已复制", "Full report copied"),
            isError: false
        )
        DebugFileLogger.log("issue reporter: full report copied")
    }

    private func openGitHubIssue() {
        let inputs = reportInputs()
        copyToPasteboard(inputs.report)

        guard let url = IssueReportService.githubIssueURL(
            title: inputs.title,
            description: problemDescription,
            environment: environment,
            includeLogs: includeLogs,
            logText: inputs.log
        ) else {
            reportStatus = ReportStatus(
                message: L("无法生成链接，完整报告已复制", "Could not create the link; full report copied"),
                isError: true
            )
            return
        }

        if NSWorkspace.shared.open(url) {
            reportStatus = ReportStatus(
                message: L("已打开 GitHub，完整报告也已复制", "GitHub opened; the full report is also copied"),
                isError: false
            )
            DebugFileLogger.log("issue reporter: GitHub new issue opened")
        } else {
            reportStatus = ReportStatus(
                message: L("无法打开浏览器，完整报告已复制", "Could not open the browser; full report copied"),
                isError: true
            )
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct ReportStatus {
    let message: String
    let isError: Bool
}
