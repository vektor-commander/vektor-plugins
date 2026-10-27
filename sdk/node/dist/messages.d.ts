import type { Block, Role } from './blocks';
import type { ViewDescription } from './view';
export type JSONValue = null | boolean | number | string | JSONValue[] | {
    [key: string]: JSONValue;
};
export type JSONObject = {
    [key: string]: JSONValue;
};
/** The method names, as the wire spells them. */
export declare const Methods: {
    readonly startup: 'startup';
    readonly shutdown: 'shutdown';
    readonly invoke: 'invoke';
    readonly settingsChanged: 'settingsChanged';
    readonly viewOpened: 'view/opened';
    readonly viewClosed: 'view/closed';
    readonly viewEvent: 'view/event';
    /** API 2: Vektor could not show a description or a patch (`ViewRefusedParams`). */
    readonly viewRefused: 'view/refused';
    readonly webMessage: 'web/message';
    readonly workspaceChanged: 'workspace/changed';
    readonly processOutput: 'process/output';
    readonly processExited: 'process/exited';
    readonly ping: 'ping';
    readonly cancel: '$/cancel';
    readonly decorationsGet: 'decorations/get';
    readonly infoGet: 'info/get';
    readonly footerGet: 'footer/get';
    readonly log: 'log';
    readonly toast: 'toast';
    readonly alert: 'alert';
    readonly confirm: 'confirm';
    readonly clipboardWriteText: 'clipboard/writeText';
    readonly settingsGet: 'settings/get';
    readonly settingsStatus: 'settings/status';
    readonly dialogShow: 'dialog/show';
    readonly viewUpdate: 'view/update';
    readonly viewPatch: 'view/patch';
    readonly sidebarItems: 'sidebar/items';
    readonly sidebarBadge: 'sidebar/badge';
    readonly webPost: 'web/post';
    readonly openURL: 'openURL';
    readonly navigate: 'navigate';
    readonly reveal: 'reveal';
    readonly processStart: 'process/start';
    readonly processStop: 'process/stop';
    readonly secretsRead: 'secrets/read';
    readonly secretsWrite: 'secrets/write';
    readonly secretsDelete: 'secrets/delete';
    readonly storageStatus: 'storage/status';
    readonly storageList: 'storage/list';
    readonly storageRead: 'storage/read';
    readonly storageWrite: 'storage/write';
    readonly storageDelete: 'storage/delete';
    readonly storageCreateFolder: 'storage/createFolder';
    readonly decorationsChanged: 'decorations/changed';
    readonly footerChanged: 'footer/changed';
};
/** Methods Vektor sends as notifications (no answer). Every other method Vektor sends is a request. */
export declare const VEKTOR_NOTIFICATIONS: ReadonlySet<string>;
export type Tone = 'positive' | 'neutral' | 'warning' | 'error';
/** The active workspace, or null. */
export interface Workspace {
    id: string;
    name: string;
}
/** A `place` setting's value: an opaque handle. Pass `place` back unchanged; never store it across runs. */
export interface PlaceHandle {
    place: string;
    label: string;
    remote: boolean;
}
/** A file or folder Vektor hands the plugin: a path on this Mac, or a `location` for an S3, SFTP or container item. */
export interface Item {
    path?: string;
    location?: string;
    remote?: boolean;
    name: string;
    isFolder: boolean;
    size?: number;
    modified?: string | number;
    [key: string]: unknown;
}
export interface InvokeTarget {
    menu?: string;
    items?: Item[];
    /** The folder the menu was opened in: its path (Vektor sends a string here, not an item). */
    folder?: string;
    connection?: {
        id: string;
        kind: string;
    };
    website?: {
        url: string;
        name: string;
    };
    text?: string;
    /** The sidebar entry a menu belongs to. */
    entry?: string;
    /** API 2: the sidebar item a `sidebarItem` menu belongs to. */
    item?: string;
    /** `drop` or `footer` for those sources. */
    source?: 'drop' | 'footer';
    surface?: 'sidebarEntry' | 'view';
    view?: string;
    [key: string]: unknown;
}
export interface StartupParams {
    vektorVersion: string;
    pluginID: string;
    previousSessionEndedUncleanly: boolean;
    sessionTemporaryFolder: string;
    dataFolder: string;
    settings: JSONObject;
    workspace: Workspace | null;
}
export type ShutdownReason = 'quit' | 'disable' | 'uninstall' | 'update' | 'crashRestart' | 'endOfInput' | string;
export interface ShutdownParams {
    reason: ShutdownReason;
}
export interface InvokeParams {
    command: string;
    target: InvokeTarget;
}
/** `{}`, or a message shown as a short notice. */
export interface InvokeResult {
    message?: string;
}
export interface SettingsChangedParams {
    settings: JSONObject;
    workspace: Workspace | null;
}
export interface ViewOpenedParams {
    view: string;
    item?: string;
}
export interface ViewClosedParams {
    view: string;
    item?: string;
}
/** A file dropped on a block (`fileDrop`): local items only. */
export interface DroppedFile {
    path: string;
    name: string;
    isFolder: boolean;
}
export interface ViewEventParams {
    view: string;
    action: string;
    revision?: number;
    card?: string;
    value?: JSONValue;
    field?: string;
    before?: string;
    index?: number;
    group?: string;
    block?: string;
    item?: string;
    from?: string;
    target?: string;
    files?: DroppedFile[];
    column?: string;
    ascending?: boolean;
    selected?: string[];
    [key: string]: unknown;
}
/**
 * `view/refused` (API 2): Vektor could not show what the plugin sent for a view — a whole description (`view/update`) or a
 * patch (`view/patch`) — and keeps showing what it showed. `revision` is the revision Vektor **still shows** (`null` while the
 * view has no numbered description): every `view/event` keeps carrying it until the plugin sends something Vektor can show, so
 * an event made against it is not stale. The answer is the whole description again, numbered above anything sent (`ViewState`
 * does that for a refused patch). An `"api": 1` plugin is never sent one; its refusals are only in the Log.
 */
export interface ViewRefusedParams {
    view: string;
    /** `description` or `patch` (a newer Vektor may add kinds). */
    kind: 'description' | 'patch' | string;
    /** The revision Vektor still shows: the one its events carry. */
    revision: number | null;
    /** The revision the refused message carried, when it had one. */
    refusedRevision?: number;
    /** Why, in plain words (as the Log says it). */
    problem: string;
}
export interface WebMessageParams {
    view: string;
    block?: string;
    message: JSONValue;
}
export interface WorkspaceChangedParams {
    id: string;
    name: string;
}
export interface ProcessOutputParams {
    processID: string;
    stream: 'stdout' | 'stderr';
    text: string;
}
export interface ProcessExitedParams {
    processID: string;
    status: number;
}
export interface CancelParams {
    id: number | string;
}
export type DecorationSymbol = 'dot' | 'check' | 'modified' | 'added' | 'removed' | 'untracked' | 'conflict' | 'warning' | 'error' | 'ignored' | 'synced' | 'uploading' | 'downloading' | 'cloud' | 'locked' | 'star' | 'clock' | 'info';
export interface DecorationsGetParams {
    items: (Item & {
        id: string;
    })[];
}
export interface Decoration {
    id: string;
    symbol: DecorationSymbol;
    tone?: Tone;
    label: string;
}
export interface DecorationsGetResult {
    decorations: Decoration[];
}
export interface InfoGetParams {
    item: Item;
}
export interface InfoGetResult {
    rows: {
        label: string;
        value: string;
    }[];
}
export interface FooterGetParams {
    folder: Item;
    location?: string;
}
export type FooterGetResult = {
    text: string;
    symbol?: string;
    label?: string;
} | Record<string, never>;
export type LogLevel = 'debug' | 'info' | 'warning' | 'error';
export interface LogParams {
    level: LogLevel;
    message: string;
}
export interface ToastParams {
    message: string;
}
export interface AlertParams {
    title: string;
    message: string;
}
export interface ConfirmParams {
    title: string;
    message: string;
    confirmTitle?: string;
}
export interface ConfirmResult {
    confirmed: boolean;
}
export interface ClipboardWriteTextParams {
    text: string;
}
export interface SettingsGetResult {
    settings: JSONObject;
    workspace: Workspace | null;
}
export interface SettingsStatusParams {
    key: string;
    text: string;
    tone?: Tone;
    detail?: string;
}
/** A dialog field: the same kinds and rules as a setting, plus `readOnlyPath`. */
export interface DialogField {
    key: string;
    kind: 'text' | 'number' | 'toggle' | 'choice' | 'path' | 'secret' | 'list' | 'readOnlyPath';
    label: string;
    help?: string;
    default?: JSONValue;
    required?: boolean;
    placeholder?: string;
    pattern?: string;
    multiline?: boolean;
    min?: number;
    max?: number;
    unit?: string;
    integer?: boolean;
    options?: {
        value: string;
        title: string;
    }[];
    style?: 'picker' | 'radio';
    pathKind?: 'folder' | 'file';
    itemKind?: 'text' | 'number';
    path?: string;
    banner?: {
        text: string;
        linkTitle?: string;
        link?: string;
    };
    [key: string]: unknown;
}
export interface DialogSection {
    id: string;
    title: string;
    open?: boolean;
    fields: DialogField[];
}
export interface DialogShowParams {
    title: string;
    subtitle?: string;
    primary?: string;
    cancel?: string;
    fields?: DialogField[];
    sections?: DialogSection[];
}
/** `values` is `{}` when the dialog was cancelled (the SDK fills it in: an older Vektor sends none then). */
export interface DialogShowResult {
    result: 'submit' | 'cancel';
    values: JSONObject;
}
export interface ViewUpdateParams {
    view: string;
    description: ViewDescription;
}
export type PatchOperation = {
    op: 'replace';
    id: string;
    block: Block;
} | {
    op: 'insert';
    parent: string;
    index?: number;
    block: Block;
} | {
    op: 'remove';
    id: string;
} | {
    op: 'move';
    id: string;
    parent: string;
    index?: number;
};
export interface ViewPatchParams {
    view: string;
    revision?: number;
    ops: PatchOperation[];
}
export interface SidebarItem {
    id: string;
    title: string;
    symbol?: string;
    badge?: string | number;
}
export interface SidebarItemsParams {
    entry: string;
    items: SidebarItem[];
}
export interface SidebarBadgeParams {
    entry: string;
    count?: number;
    text?: string;
    tone?: Tone;
    symbol?: string;
    label?: string;
}
export interface WebPostParams {
    view: string;
    block?: string;
    message: JSONValue;
}
export interface OpenURLParams {
    url: string;
}
export interface NavigateParams {
    path: string;
    placement?: 'newTab' | 'otherPane';
}
export interface RevealParams {
    path: string;
}
export interface ProcessStartParams {
    executable: string;
    arguments?: string[];
    environment?: Record<string, string>;
    workingDirectory?: string;
}
export interface ProcessStartResult {
    processID: string;
}
export interface ProcessStopParams {
    processID: string;
}
export interface SecretsReadParams {
    key: string;
}
export interface SecretsReadResult {
    value: string;
}
export interface SecretsWriteParams {
    key: string;
    value: string;
}
export interface SecretsDeleteParams {
    key: string;
}
export type StorageState = 'available' | 'offline' | 'needsSignIn' | 'missing';
/** For a place Vektor cannot reach it answers only `state` (and maybe `label`): the SDK fills `''` and `false` in. */
export interface StorageStatusResult {
    state: StorageState;
    label: string;
    remote: boolean;
    writes: 'atomic' | string;
    conditional: 'atomic' | 'checked' | string;
}
export interface StorageEntry {
    name: string;
    isFolder: boolean;
    size?: number;
    modified?: string | number;
    version?: string;
}
export interface StorageListParams {
    place: string;
    path?: string;
    cursor?: string;
    limit?: number;
}
export interface StorageListResult {
    entries: StorageEntry[];
    next?: string;
}
export type StorageEncoding = 'text' | 'base64';
export interface StorageReadParams {
    place: string;
    path: string;
    offset?: number;
    length?: number;
    encoding?: StorageEncoding;
    ifVersion?: string;
}
export interface StorageReadResult {
    content: string;
    encoding: StorageEncoding;
    version: string;
    size: number;
    offset: number;
    eof: boolean;
}
export interface StorageWriteParams {
    place: string;
    path: string;
    content: string;
    encoding?: StorageEncoding;
    ifVersion?: string | null;
    upload?: string;
    more?: boolean;
}
export interface StorageWriteResult {
    version?: string;
    upload?: string;
}
export interface StorageDeleteParams {
    place: string;
    path: string;
    ifVersion?: string;
}
export interface StorageDeleteResult {
    trashed: boolean;
}
export interface StorageCreateFolderParams {
    place: string;
    path: string;
}
/** `error.code` of a refused storage call. */
export type StorageErrorCode = 'changed' | 'notFound' | 'exists' | 'wrongKind' | 'badPath' | 'badPlace' | 'badCursor' | 'missing' | 'offline' | 'needsSignIn' | 'unavailable' | 'tooLarge' | 'badRequest' | 'refused' | 'failed';
export interface DecorationsChangedParams {
    paths?: string[];
}
/** What each request the plugin may send answers. */
export interface PluginRequests {
    confirm: [ConfirmParams, ConfirmResult];
    'settings/get': [Record<string, never>, SettingsGetResult];
    'dialog/show': [DialogShowParams, DialogShowResult];
    openURL: [OpenURLParams, Record<string, never>];
    navigate: [NavigateParams, Record<string, never>];
    reveal: [RevealParams, Record<string, never>];
    'process/start': [ProcessStartParams, ProcessStartResult];
    'process/stop': [ProcessStopParams, Record<string, never>];
    'secrets/read': [SecretsReadParams, SecretsReadResult];
    'secrets/write': [SecretsWriteParams, Record<string, never>];
    'secrets/delete': [SecretsDeleteParams, Record<string, never>];
    'storage/status': [{
        place: string;
    }, StorageStatusResult];
    'storage/list': [StorageListParams, StorageListResult];
    'storage/read': [StorageReadParams, StorageReadResult];
    'storage/write': [StorageWriteParams, StorageWriteResult];
    'storage/delete': [StorageDeleteParams, StorageDeleteResult];
    'storage/createFolder': [StorageCreateFolderParams, Record<string, never>];
}
/** What each notification the plugin may send carries. */
export interface PluginNotifications {
    log: LogParams;
    toast: ToastParams;
    alert: AlertParams;
    'clipboard/writeText': ClipboardWriteTextParams;
    'settings/status': SettingsStatusParams;
    'view/update': ViewUpdateParams;
    'view/patch': ViewPatchParams;
    'sidebar/items': SidebarItemsParams;
    'sidebar/badge': SidebarBadgeParams;
    'web/post': WebPostParams;
    'decorations/changed': DecorationsChangedParams;
    'footer/changed': Record<string, never>;
}
/** A role, re-exported for messages that name one. */
export type { Role };
