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
import {
  button, datePicker, hstack, picker, rolePicker, scroll, section, spacer, stepper, tagPicker, text, textArea, textField, toggle, vstack,
  type Block, type Option, type Role,
} from '../blocks';
import type { ViewEvent, ViewState } from '../view';
import { scoped, unscoped } from './support';

interface FieldBase { key: string; label: string; help?: string; error?: string; enabled?: boolean }
export type SettingsField =
  | (FieldBase & { kind: 'text'; value?: string; placeholder?: string })
  | (FieldBase & { kind: 'textArea'; value?: string; placeholder?: string })
  | (FieldBase & { kind: 'toggle'; value?: boolean })
  | (FieldBase & { kind: 'picker'; options: Option[]; value?: string; segmented?: boolean })
  | (FieldBase & { kind: 'stepper'; value?: number; min?: number; max?: number; step?: number })
  | (FieldBase & { kind: 'date'; value?: string })
  | (FieldBase & { kind: 'tags'; tags?: string[]; suggestions?: string[] })
  | (FieldBase & { kind: 'role'; value?: Role; roles?: Role[] })
  /** A button on its own line: `label` is the text beside it, `title` its own. */
  | (FieldBase & { kind: 'button'; title: string; symbol?: string; style?: 'primary' | 'plain' | 'destructive' });

export interface SettingsSection {
  id: string;
  title?: string;
  /** A line under the title. */
  description?: string;
  collapsible?: boolean;
  collapsed?: boolean;
  fields: SettingsField[];
}

export interface SettingsFormSpec {
  /** Prefix of every block id and action (default `settings`). */
  id?: string;
  sections: SettingsSection[];
}

function control(prefix: string, field: SettingsField): Block {
  const id = scoped(prefix, 'field', field.key);
  const change = scoped(prefix, 'change');
  switch (field.kind) {
    case 'text': return textField(id, change, { value: field.value ?? '', placeholder: field.placeholder, error: field.error, enabled: field.enabled });
    case 'textArea': return textArea(id, change, { value: field.value ?? '', placeholder: field.placeholder, error: field.error, enabled: field.enabled });
    case 'toggle': return toggle(id, change, { value: field.value ?? false, enabled: field.enabled });
    case 'picker': return picker(id, change, field.options, { value: field.value, style: field.segmented ? 'segmented' : undefined, enabled: field.enabled });
    case 'stepper': return stepper(id, change, { value: field.value, min: field.min, max: field.max, step: field.step, enabled: field.enabled });
    case 'date': return datePicker(id, change, { value: field.value, enabled: field.enabled });
    case 'tags': return tagPicker(id, change, { tags: field.tags ?? [], suggestions: field.suggestions, enabled: field.enabled });
    case 'role': return rolePicker(id, change, { value: field.value, roles: field.roles, enabled: field.enabled });
    case 'button': return button({ id, title: field.title, symbol: field.symbol, style: field.style, action: scoped(prefix, 'press'), enabled: field.enabled });
  }
}

function fieldRow(prefix: string, field: SettingsField): Block {
  // A text area is wide: its label goes above it instead of beside it.
  const labelColumn = vstack([
    text(field.label, { id: scoped(prefix, 'label', field.key) }),
    ...(field.help ? [text(field.help, { id: scoped(prefix, 'help', field.key), style: 'caption' })] : []),
  ], { id: scoped(prefix, 'text', field.key) });
  const rowID = scoped(prefix, 'row', field.key);
  return field.kind === 'textArea'
    ? vstack([labelColumn, control(prefix, field)], { id: rowID })
    : hstack([labelColumn, spacer(), control(prefix, field)], { id: rowID });
}

export function settingsForm(spec: SettingsFormSpec): Block {
  const prefix = spec.id ?? 'settings';
  return scroll([vstack(spec.sections.map((group) => section(
    scoped(prefix, 'section', group.id),
    [
      ...(group.description ? [text(group.description, { id: scoped(prefix, 'description', group.id), style: 'caption' })] : []),
      ...group.fields.map((field) => fieldRow(prefix, field)),
    ],
    { title: group.title, collapsible: group.collapsible, collapsed: group.collapsed },
  )), { id: scoped(prefix, 'sections') })], { id: prefix, axis: 'vertical' });
}

export interface SettingsFormHandlers {
  /** A field changed. `value` is what the control sends: text, true/false, a number, `yyyy-MM-dd`, a list of tags, a role. */
  onChange?(key: string, value: unknown, event: ViewEvent): unknown;
  /** A button field was pressed. */
  onButton?(key: string, event: ViewEvent): unknown;
}

/** Sends the form's events to `handlers`. Call once, when the view is set up. */
export function routeSettingsForm(view: ViewState, options: Pick<SettingsFormSpec, 'id'>, handlers: SettingsFormHandlers): void {
  const prefix = options.id ?? 'settings';
  view.on(scoped(prefix, 'change'), (event) => {
    const key = unscoped(prefix, 'field', event.block);
    return key === undefined ? undefined : handlers.onChange?.(key, event.value, event);
  }, { stale: 'deliver' });   // text typed in quick succession must never be lost
  view.on(scoped(prefix, 'press'), (event) => {
    const key = unscoped(prefix, 'field', event.block);
    return key === undefined ? undefined : handlers.onButton?.(key, event);
  });
}
