// Board — Kanban boards for each workspace, on the Vektor SDK for Swift (plugin API 2).
//
// What is here: the wiring between Vektor and the controller. The startup and every workspace switch or place change
// activate that workspace's boards; the sidebar entry lists them (and is sent again whenever they change); the entry's menu
// creates a board, an item's menu renames or deletes one.
//
// The board and list views, the task screen, Board settings and the questions after a sync are drawn from the controller's
// queries (BoardQueries.swift) and call its commands: BoardViewModel.swift routes the events, BoardScreens.swift builds the blocks.
//
// Rules this plugin keeps:
//   * Storage only through Vektor's storage service (the `storage` permission): no credentials, no S3, SFTP or SMB code.
//   * stdout carries messages only (the SDK sees to it); the Log gets counts and plain words, never a board's contents.
//   * The program is signed ad hoc by build.sh after the last change.
import Foundation
import VektorPlugin

/// The ids the manifest uses.
public enum BoardIDs {
    public static let view = "board"
    public static let sidebarEntry = "boards"
    /// The `place` setting (per workspace).
    public static let placeSetting = "place"
    public static let newBoard = "newBoard"
    public static let renameBoard = "renameBoard"
    public static let deleteBoard = "deleteBoard"
}

/// Registers everything the plugin does. The program calls it (Sources/board/main.swift); so do the tests.
@MainActor
@discardableResult
public func setup(_ plugin: Plugin, options: BoardController.Options = BoardController.Options()) -> Plugin {
    let controller = BoardController(plugin: plugin, options: options)
    let sidebar = plugin.sidebar(BoardIDs.sidebarEntry)
    let view = plugin.view(BoardIDs.view)
    let model = BoardViewModel(plugin: plugin, controller: controller, view: view)
    BoardPluginState.shared[ObjectIdentifier(plugin)] = controller
    BoardPluginState.models[ObjectIdentifier(plugin)] = model

    func activate() async {
        if let folder = plugin.dataFolder { controller.dataFolder = URL(fileURLWithPath: folder) }
        await controller.activate(workspace: plugin.workspace, place: plugin.place(BoardIDs.placeSetting))
    }

    // The board the view shows is marked in the sidebar (Vektor highlights the item it opened too; this marks it after a switch
    // made inside the view).
    sidebar.provide { _ in
        let shown = model.boardID
        return controller.boards.map { SidebarItem(id: $0.id, title: $0.name, symbol: $0.id == shown ? "rectangle.split.3x1.fill" : "rectangle.split.3x1") }
    }
    model.onCurrentChange = { Task { @MainActor in try? await sidebar.refresh() } }
    controller.onChange = { change in
        switch change {
        case .boards, .workspace:
            Task { @MainActor in try? await sidebar.refresh() }
        case .board, .sync:
            break
        }
        model.changed(change)
    }

    plugin.onStartup { _ in await activate() }
    plugin.onSettingsChanged { _, _ in await activate() }
    plugin.onWorkspaceChanged { _ in await activate() }

    /// A refusal from the board (`BoardError`) reaches Vektor in its own plain words, not as "something went wrong".
    func plainWords(_ work: () async throws -> Void) async throws -> InvokeResult {
        do { try await work() } catch let error as BoardError { throw PluginError(error.message) }
        return InvokeResult()
    }
    plugin.command(BoardIDs.newBoard) { _, _ in try await plainWords { try await model.askNewBoard() } }
    sidebar.onMenu(BoardIDs.renameBoard) { item, _, _ in try await plainWords { try await model.askRenameBoard(item) } }
    sidebar.onMenu(BoardIDs.deleteBoard) { item, _, _ in try await plainWords { try await model.askDeleteBoard(item) } }

    return plugin
}
/// The controller of each running plugin object (a test may run several), for the views and the tests.
@MainActor
public enum BoardPluginState {
    public static var shared: [ObjectIdentifier: BoardController] = [:]
    public static var models: [ObjectIdentifier: BoardViewModel] = [:]
    public static func model(of plugin: Plugin) -> BoardViewModel? { models[ObjectIdentifier(plugin)] }
    public static func controller(of plugin: Plugin) -> BoardController? { shared[ObjectIdentifier(plugin)] }
}
