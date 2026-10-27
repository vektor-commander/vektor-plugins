"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.MIN_VEKTOR = exports.PLUGIN_API = exports.SDK_VERSION = void 0;
/** This SDK's own version (it is versioned separately from Vektor). */
exports.SDK_VERSION = '0.1.0';
/** The plugin API this SDK targets (it also speaks to API 1 plugins, which never receive an API 2 message). */
exports.PLUGIN_API = 2;
/** The oldest Vektor this SDK needs for everything it offers (block views, storage places, web views: plugin API 2). */
exports.MIN_VEKTOR = '1.0.0';
