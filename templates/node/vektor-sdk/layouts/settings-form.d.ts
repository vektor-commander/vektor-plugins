import { type Block, type Option, type Role } from '../blocks';
import type { ViewEvent, ViewState } from '../view';
interface FieldBase {
    key: string;
    label: string;
    help?: string;
    error?: string;
    enabled?: boolean;
}
export type SettingsField = (FieldBase & {
    kind: 'text';
    value?: string;
    placeholder?: string;
}) | (FieldBase & {
    kind: 'textArea';
    value?: string;
    placeholder?: string;
}) | (FieldBase & {
    kind: 'toggle';
    value?: boolean;
}) | (FieldBase & {
    kind: 'picker';
    options: Option[];
    value?: string;
    segmented?: boolean;
}) | (FieldBase & {
    kind: 'stepper';
    value?: number;
    min?: number;
    max?: number;
    step?: number;
}) | (FieldBase & {
    kind: 'date';
    value?: string;
}) | (FieldBase & {
    kind: 'tags';
    tags?: string[];
    suggestions?: string[];
}) | (FieldBase & {
    kind: 'role';
    value?: Role;
    roles?: Role[];
})
/** A button on its own line: `label` is the text beside it, `title` its own. */
 | (FieldBase & {
    kind: 'button';
    title: string;
    symbol?: string;
    style?: 'primary' | 'plain' | 'destructive';
});
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
export declare function settingsForm(spec: SettingsFormSpec): Block;
export interface SettingsFormHandlers {
    /** A field changed. `value` is what the control sends: text, true/false, a number, `yyyy-MM-dd`, a list of tags, a role. */
    onChange?(key: string, value: unknown, event: ViewEvent): unknown;
    /** A button field was pressed. */
    onButton?(key: string, event: ViewEvent): unknown;
}
/** Sends the form's events to `handlers`. Call once, when the view is set up. */
export declare function routeSettingsForm(view: ViewState, options: Pick<SettingsFormSpec, 'id'>, handlers: SettingsFormHandlers): void;
export {};
