// The Vektor plugin SDK for Node.js. Everything is plain protocol (docs/reference.md); this package adds types, the parts
// every plugin gets wrong once, and helpers for views, the sidebar, workspaces, storage, sync and web views.

export * from './errors';
export * from './framing';
export * from './messages';
export * from './transport';
export * from './plugin';
export * as blocks from './blocks';
export { ROLES, ROLE_TITLES, WIDTHS, validateBlocks, type Block, type Role, type MenuEntry, type Control, type Badge, type Column } from './blocks';
export * from './view';
export * from './storage';
export * from './sync';
export * from './sidebar';
export * from './workspace';
export * from './web';
// Layouts: `layouts.board`, `layouts.routeBoard`, … (also exported flat below, without the small shared helpers).
export * as layouts from './layouts';
export * from './layouts/board';
export * from './layouts/list-detail';
export * from './layouts/table-toolbar';
export * from './layouts/settings-form';
export * from './layouts/card-list';
export * from './version';
