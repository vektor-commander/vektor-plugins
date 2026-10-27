"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.settingsForm = settingsForm;
exports.routeSettingsForm = routeSettingsForm;
// Settings-style form: sections of labelled fields, the way a preferences page reads.
//
//     view.show({ blocks: settingsForm({ sections }) });
//     routeSettingsForm(view, {}, { onChange: (key, value) => …, onButton: (key) => … });
//
// Each field is a row: the label (and a line of help under it) on the left, the control on the right. A field has a `key`
// of yours; every change arrives as `onChange(key, value)` with the new value (text, true/false, a number, a date, a list of
// tags, a colour role), and a button field as `onButton(key)`. Keep the values in your own state and draw again: a field
// shows what you pass as `value`, so a value you refuse simply snaps back (and `error` says why).
//
// Blocks cannot show a password field; keep secrets in a `secret` setting of the manifest, which Vektor draws. Copy and adapt.
const blocks_1 = require("../blocks");
const support_1 = require("./support");
function control(prefix, field) {
    const id = (0, support_1.scoped)(prefix, 'field', field.key);
    const change = (0, support_1.scoped)(prefix, 'change');
    switch (field.kind) {
        case 'text': return (0, blocks_1.textField)(id, change, { value: field.value ?? '', placeholder: field.placeholder, error: field.error, enabled: field.enabled });
        case 'textArea': return (0, blocks_1.textArea)(id, change, { value: field.value ?? '', placeholder: field.placeholder, error: field.error, enabled: field.enabled });
        case 'toggle': return (0, blocks_1.toggle)(id, change, { value: field.value ?? false, enabled: field.enabled });
        case 'picker': return (0, blocks_1.picker)(id, change, field.options, { value: field.value, style: field.segmented ? 'segmented' : undefined, enabled: field.enabled });
        case 'stepper': return (0, blocks_1.stepper)(id, change, { value: field.value, min: field.min, max: field.max, step: field.step, enabled: field.enabled });
        case 'date': return (0, blocks_1.datePicker)(id, change, { value: field.value, enabled: field.enabled });
        case 'tags': return (0, blocks_1.tagPicker)(id, change, { tags: field.tags ?? [], suggestions: field.suggestions, enabled: field.enabled });
        case 'role': return (0, blocks_1.rolePicker)(id, change, { value: field.value, roles: field.roles, enabled: field.enabled });
        case 'button': return (0, blocks_1.button)({ id, title: field.title, symbol: field.symbol, style: field.style, action: (0, support_1.scoped)(prefix, 'press'), enabled: field.enabled });
    }
}
function fieldRow(prefix, field) {
    // A text area is wide: its label goes above it instead of beside it.
    const labelColumn = (0, blocks_1.vstack)([
        (0, blocks_1.text)(field.label, { id: (0, support_1.scoped)(prefix, 'label', field.key) }),
        ...(field.help ? [(0, blocks_1.text)(field.help, { id: (0, support_1.scoped)(prefix, 'help', field.key), style: 'caption' })] : []),
    ], { id: (0, support_1.scoped)(prefix, 'text', field.key) });
    const rowID = (0, support_1.scoped)(prefix, 'row', field.key);
    return field.kind === 'textArea'
        ? (0, blocks_1.vstack)([labelColumn, control(prefix, field)], { id: rowID })
        : (0, blocks_1.hstack)([labelColumn, (0, blocks_1.spacer)(), control(prefix, field)], { id: rowID });
}
function settingsForm(spec) {
    const prefix = spec.id ?? 'settings';
    return (0, blocks_1.scroll)([(0, blocks_1.vstack)(spec.sections.map((group) => (0, blocks_1.section)((0, support_1.scoped)(prefix, 'section', group.id), [
            ...(group.description ? [(0, blocks_1.text)(group.description, { id: (0, support_1.scoped)(prefix, 'description', group.id), style: 'caption' })] : []),
            ...group.fields.map((field) => fieldRow(prefix, field)),
        ], { title: group.title, collapsible: group.collapsible, collapsed: group.collapsed })), { id: (0, support_1.scoped)(prefix, 'sections') })], { id: prefix, axis: 'vertical' });
}
/** Sends the form's events to `handlers`. Call once, when the view is set up. */
function routeSettingsForm(view, options, handlers) {
    const prefix = options.id ?? 'settings';
    view.on((0, support_1.scoped)(prefix, 'change'), (event) => {
        const key = (0, support_1.unscoped)(prefix, 'field', event.block);
        return key === undefined ? undefined : handlers.onChange?.(key, event.value, event);
    }, { stale: 'deliver' }); // text typed in quick succession must never be lost
    view.on((0, support_1.scoped)(prefix, 'press'), (event) => {
        const key = (0, support_1.unscoped)(prefix, 'field', event.block);
        return key === undefined ? undefined : handlers.onButton?.(key, event);
    });
}
