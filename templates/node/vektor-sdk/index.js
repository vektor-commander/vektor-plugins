"use strict";
// The Vektor plugin SDK for Node.js. Everything is plain protocol (docs/reference.md); this package adds types, the parts
// every plugin gets wrong once, and helpers for views, the sidebar, workspaces, storage, sync and web views.
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
var __exportStar = (this && this.__exportStar) || function(m, exports) {
    for (var p in m) if (p !== "default" && !Object.prototype.hasOwnProperty.call(exports, p)) __createBinding(exports, m, p);
};
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
exports.layouts = exports.validateBlocks = exports.WIDTHS = exports.ROLE_TITLES = exports.ROLES = exports.blocks = void 0;
__exportStar(require("./errors"), exports);
__exportStar(require("./framing"), exports);
__exportStar(require("./messages"), exports);
__exportStar(require("./transport"), exports);
__exportStar(require("./plugin"), exports);
exports.blocks = __importStar(require("./blocks"));
var blocks_1 = require("./blocks");
Object.defineProperty(exports, "ROLES", { enumerable: true, get: function () { return blocks_1.ROLES; } });
Object.defineProperty(exports, "ROLE_TITLES", { enumerable: true, get: function () { return blocks_1.ROLE_TITLES; } });
Object.defineProperty(exports, "WIDTHS", { enumerable: true, get: function () { return blocks_1.WIDTHS; } });
Object.defineProperty(exports, "validateBlocks", { enumerable: true, get: function () { return blocks_1.validateBlocks; } });
__exportStar(require("./view"), exports);
__exportStar(require("./storage"), exports);
__exportStar(require("./sync"), exports);
__exportStar(require("./sidebar"), exports);
__exportStar(require("./workspace"), exports);
__exportStar(require("./web"), exports);
// Layouts: `layouts.board`, `layouts.routeBoard`, … (also exported flat below, without the small shared helpers).
exports.layouts = __importStar(require("./layouts"));
__exportStar(require("./layouts/board"), exports);
__exportStar(require("./layouts/list-detail"), exports);
__exportStar(require("./layouts/table-toolbar"), exports);
__exportStar(require("./layouts/settings-form"), exports);
__exportStar(require("./layouts/card-list"), exports);
__exportStar(require("./version"), exports);
