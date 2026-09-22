import CodexBarCore
import Commander
import Foundation

struct CardsOptions: CommanderParsable {
    @OptionGroup
    var logging: CLILoggingOptions

    @OptionGroup
    var fetch: CLIUsageFetchOptions

    @Flag(name: .long("brief"), help: "Compact table layout instead of the card grid")
    var brief: Bool = false
}

extension CodexBarCLI {
    static func runCards(_ values: ParsedValues) async {
        let output = CLIOutputPreferences.from(values: values)
        let config = Self.loadConfig(output: output)
        let provider = Self.decodeProvider(from: values, config: config)
        let includeCredits = !values.flags.contains("noCredits")
        let includeStatus = values.flags.contains("status")
        let sourceModeRaw = values.options["source"]?.last
        let parsedSourceMode = Self.decodeSourceMode(from: values)
        if sourceModeRaw != nil, parsedSourceMode == nil {
            Self.exit(
                code: .failure,
                message: "Error: --source must be auto|web|cli|oauth|api.",
                output: output,
                kind: .args)
        }
        let antigravityPlanDebug = values.flags.contains("antigravityPlanDebug")
        let augmentDebug = values.flags.contains("augmentDebug")
        let webDebugDumpHTML = values.flags.contains("webDebugDumpHtml")
        let webTimeout: TimeInterval
        do {
            webTimeout = try Self.decodeWebTimeout(from: values) ?? 60
        } catch {
            Self.exit(code: .failure, message: "Error: \(error.localizedDescription)", output: output, kind: .args)
        }
        let verbose = values.flags.contains("verbose")
        let noColor = values.flags.contains("noColor")
        let useColor = Self.shouldUseColor(noColor: noColor, format: .text)
        let brief = values.flags.contains("brief")
        let resetStyle = Self.resetTimeDisplayStyleFromDefaults()
        let weeklyWorkDays = Self.weeklyProgressWorkDaysFromDefaults()
        let providerList = provider.asList
        // Provider-specific by design: claude-swap cards need Claude's integration configuration and subprocess.
        let claudeConfig = config.providerConfig(for: .claude)

        let tokenSelection: TokenAccountCLISelection
        do {
            tokenSelection = try Self.decodeTokenAccountSelection(from: values)
        } catch {
            Self.exit(code: .failure, message: "Error: \(error.localizedDescription)", output: output, kind: .args)
        }

        if tokenSelection.allAccounts, tokenSelection.label != nil || tokenSelection.index != nil {
            Self.exit(
                code: .failure,
                message: "Error: --all-accounts cannot be combined with --account or --account-index.",
                output: output,
                kind: .args)
        }

        if let message = tokenSelection.providerSelectionError(providerList) {
            Self.exit(code: .failure, message: "Error: \(message)", output: output, kind: .args)
        }

        let browserDetection = BrowserDetection()
        let fetcher = UsageFetcher()
        let claudeFetcher = ClaudeUsageFetcher(browserDetection: browserDetection)
        let tokenContext: TokenAccountCLIContext
        do {
            tokenContext = try TokenAccountCLIContext(
                selection: tokenSelection,
                config: config,
                verbose: verbose)
        } catch {
            Self.exit(code: .failure, message: "Error: \(error.localizedDescription)", output: output, kind: .config)
        }

        var cards: [CLICardModel] = []
        var failures: [CLICardFailure] = []
        var exitCode: ExitCode = .success
        let command = UsageCommandContext(
            format: .text,
            includeCredits: includeCredits,
            sourceModeOverride: parsedSourceMode,
            antigravityPlanDebug: antigravityPlanDebug,
            augmentDebug: augmentDebug,
            webDebugDumpHTML: webDebugDumpHTML,
            webTimeout: webTimeout,
            verbose: verbose,
            useColor: useColor,
            resetStyle: resetStyle,
            weeklyWorkDays: weeklyWorkDays,
            jsonOnly: output.jsonOnly,
            includeAllCodexAccounts: tokenSelection.allAccounts && providerList == [.codex],
            fetcher: fetcher,
            claudeFetcher: claudeFetcher,
            browserDetection: browserDetection,
            cardsLayout: true)

        for provider in providerList {
            let status = includeStatus ? await Self.fetchStatus(for: provider) : nil
            let claudeSwapEligible = CLIClaudeSwapCards.isEligible(
                provider: provider,
                integrationEnabled: claudeConfig?.claudeSwapEnabled == true,
                hasExplicitAccountSelection: tokenSelection.usesOverride,
                sourceModeOverride: parsedSourceMode)
            let result = await CLIClaudeSwapCards.fetch(
                eligible: claudeSwapEligible,
                executablePath: CLIClaudeSwapCards.executablePath(from: claudeConfig),
                showSingleAccount: claudeConfig?.claudeSwapShowSingleAccount == true,
                renderOptions: CLIClaudeSwapCardsRenderOptions(
                    status: status,
                    useColor: useColor,
                    resetStyle: resetStyle,
                    weeklyWorkDays: weeklyWorkDays,
                    now: Date()),
                ambientFetch: {
                    await ProviderInteractionContext.$current.withValue(.background) {
                        await Self.fetchUsageOutputs(
                            provider: provider,
                            status: status,
                            tokenContext: tokenContext,
                            command: command)
                    }
                })
            if result.exitCode != .success {
                exitCode = result.exitCode
            }
            cards.append(contentsOf: result.cards)
            failures.append(contentsOf: result.cardFailures)
        }

        let rendered: String
        let enhanced = CLITerminalCapabilities.supportsEnhancedCards(useColor: useColor)
        if brief {
            let rows = CLICardsBriefRenderer.makeRows(cards: cards)
            rendered = CLICardsBriefRenderer.render(
                rows: rows,
                failures: failures,
                terminalWidth: CLICardsRenderer.terminalColumnCount(),
                useColor: useColor,
                enhanced: enhanced)
        } else {
            rendered = CLICardsRenderer.render(
                cards: cards,
                failures: failures,
                terminalWidth: CLICardsRenderer.terminalColumnCount(),
                useColor: useColor,
                enhanced: enhanced)
        }
        if !rendered.isEmpty {
            print(rendered)
        }

        Self.exit(code: exitCode, output: output, kind: exitCode == .success ? .runtime : .provider)
    }
}
