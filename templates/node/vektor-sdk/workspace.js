"use strict";
// Per-workspace state. `Plugin.workspace` is always the active workspace (from `startup`, `settingsChanged` and
// `workspace/changed`); `plugin.onWorkspaceChanged` runs on a switch. `WorkspaceState` keeps one value per workspace in the
// plugin's data folder, written atomically, so "the board this workspace had open" survives a restart.
//
//     const opened = new WorkspaceState(plugin, 'opened', { board: null });
//     opened.current.board = 'b1'; opened.save();
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.WorkspaceState = exports.NO_WORKSPACE = void 0;
const fs = __importStar(require("fs"));
const path = __importStar(require("path"));
/** The key used when there is no active workspace. */
exports.NO_WORKSPACE = '';
class WorkspaceState {
    plugin;
    name;
    initial;
    folder;
    values = {};
    loaded = false;
    /**
     * `name` becomes the file `<data folder>/<name>.workspaces.json`; `initial` is a workspace's value until one is saved
     * (copied, never shared between workspaces).
     */
    constructor(plugin, name, initial, folder) {
        this.plugin = plugin;
        this.name = name;
        this.initial = initial;
        this.folder = folder;
        if (!/^[A-Za-z0-9._-]+$/.test(name))
            throw new Error('A workspace state name is letters, digits, “.”, “-” and “_”.');
    }
    get file() {
        const folder = this.folder ?? this.plugin.dataFolder;
        return folder ? path.join(folder, `${this.name}.workspaces.json`) : undefined;
    }
    load() {
        if (this.loaded)
            return;
        this.loaded = true;
        const file = this.file;
        if (!file)
            return;
        try {
            const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
            if (parsed && typeof parsed === 'object' && parsed.workspaces && typeof parsed.workspaces === 'object')
                this.values = parsed.workspaces;
        }
        catch {
            // No file yet, or one this version cannot read: start from the initial values.
        }
    }
    key(workspace) {
        return workspace?.id ?? exports.NO_WORKSPACE;
    }
    /** The value of `workspace` (default: the active one). Changes to it are kept in memory; `save()` writes them. */
    get(workspace = this.plugin.workspace) {
        this.load();
        const key = this.key(workspace);
        if (!(key in this.values))
            this.values[key] = JSON.parse(JSON.stringify(this.initial));
        return this.values[key];
    }
    /** The active workspace's value. */
    get current() {
        return this.get();
    }
    set(value, workspace = this.plugin.workspace) {
        this.load();
        this.values[this.key(workspace)] = value;
        this.save();
    }
    /** Forgets a workspace's value (a workspace that was deleted). */
    forget(workspace) {
        this.load();
        delete this.values[this.key(workspace)];
        this.save();
    }
    /** Writes every workspace's value: to a temporary file, then renamed over the real one, so a crash never leaves half. */
    save() {
        const file = this.file;
        if (!file)
            return;
        fs.mkdirSync(path.dirname(file), { recursive: true });
        const temporary = `${file}.new`;
        fs.writeFileSync(temporary, `${JSON.stringify({ version: 1, workspaces: this.values }, null, 2)}\n`);
        fs.renameSync(temporary, file);
    }
}
exports.WorkspaceState = WorkspaceState;
