"use strict";
// Typed messages: every method in the plugin reference (docs/reference.md), in both directions. Field names are exactly the
// wire's. Unknown fields are allowed everywhere (Vektor adds fields without a version bump), so these types describe what is
// there at least, never all that may be.
Object.defineProperty(exports, "__esModule", { value: true });
exports.VEKTOR_NOTIFICATIONS = exports.Methods = void 0;
/** The method names, as the wire spells them. */
exports.Methods = {
    // From Vektor
    startup: 'startup',
    shutdown: 'shutdown',
    invoke: 'invoke',
    settingsChanged: 'settingsChanged',
    viewOpened: 'view/opened',
    viewClosed: 'view/closed',
    viewEvent: 'view/event',
    /** API 2: Vektor could not show a description or a patch (`ViewRefusedParams`). */
    viewRefused: 'view/refused',
    webMessage: 'web/message',
    workspaceChanged: 'workspace/changed',
    processOutput: 'process/output',
    processExited: 'process/exited',
    ping: 'ping',
    cancel: '$/cancel',
    decorationsGet: 'decorations/get',
    infoGet: 'info/get',
    footerGet: 'footer/get',
    // From the plugin
    log: 'log',
    toast: 'toast',
    alert: 'alert',
    confirm: 'confirm',
    clipboardWriteText: 'clipboard/writeText',
    settingsGet: 'settings/get',
    settingsStatus: 'settings/status',
    dialogShow: 'dialog/show',
    viewUpdate: 'view/update',
    viewPatch: 'view/patch',
    sidebarItems: 'sidebar/items',
    sidebarBadge: 'sidebar/badge',
    webPost: 'web/post',
    openURL: 'openURL',
    navigate: 'navigate',
    reveal: 'reveal',
    processStart: 'process/start',
    processStop: 'process/stop',
    secretsRead: 'secrets/read',
    secretsWrite: 'secrets/write',
    secretsDelete: 'secrets/delete',
    storageStatus: 'storage/status',
    storageList: 'storage/list',
    storageRead: 'storage/read',
    storageWrite: 'storage/write',
    storageDelete: 'storage/delete',
    storageCreateFolder: 'storage/createFolder',
    decorationsChanged: 'decorations/changed',
    footerChanged: 'footer/changed',
};
/** Methods Vektor sends as notifications (no answer). Every other method Vektor sends is a request. */
exports.VEKTOR_NOTIFICATIONS = new Set([
    exports.Methods.settingsChanged, exports.Methods.viewOpened, exports.Methods.viewClosed, exports.Methods.viewEvent, exports.Methods.viewRefused, exports.Methods.webMessage,
    exports.Methods.workspaceChanged, exports.Methods.processOutput, exports.Methods.processExited, exports.Methods.cancel,
]);
