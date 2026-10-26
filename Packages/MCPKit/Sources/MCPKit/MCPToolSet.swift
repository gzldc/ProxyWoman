import FlowStore
import Foundation

/// The only place the tool list is assembled (spec section 4). Order is the order of `tools/list`.
public enum MCPToolSet {
    public static func make(
        app: MCPAppInfo, store: FlowStore, status: any MCPStatusSource, rules: any MCPRulesAccess,
        recording: any MCPRecordingControl
    ) -> [any MCPTool] {
        [
            GetStatusTool(app: app, flows: store, status: status),
            ListFlowsTool(store: store),
            SearchFlowsTool(store: store),
            GetFlowTool(store: store),
            ListRulesTool(rules: rules),
            ExportFlowCurlTool(store: store),
            ExportHARTool(store: store, app: app),
            CreateRuleTool(rules: rules),
            UpdateRuleTool(rules: rules),
            SetRuleEnabledTool(rules: rules),
            SetRecordingTool(recording: recording),
        ]
    }
}
