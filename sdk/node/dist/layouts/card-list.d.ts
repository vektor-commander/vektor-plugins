import { type Block, type Role } from '../blocks';
import type { ViewEvent, ViewState } from '../view';
/** A button at a card's right. `key` comes back in `onButton`; it is a word without dots (the card's id may have them). */
export interface CardButton {
    key: string;
    title?: string;
    symbol?: string;
    tooltip?: string;
    enabled?: boolean;
}
export type CardMenuEntry = {
    key: string;
    title: string;
    symbol?: string;
    destructive?: boolean;
    enabled?: boolean;
} | {
    separator: true;
};
export interface CardItem {
    id: string;
    symbol?: string;
    title: string;
    /** A word on a tinted capsule beside the title. */
    pill?: {
        label: string;
        role?: Role;
    };
    /** Lines of text under the title; one with a `link` opens it in the browser when clicked (needs `openURLs`). */
    lines?: (string | {
        text: string;
        link?: string;
    })[];
    /** The card reacts to Return or a double-click (`onOpen`). */
    openable?: boolean;
    /** Buttons at the right. */
    buttons?: CardButton[];
    /** The card's context menu. */
    menu?: CardMenuEntry[];
}
export interface CardListSpec {
    /** Prefix of every block id and action (default `cards`). */
    id?: string;
    cards: CardItem[];
    /** Shown instead of the cards when there are none. */
    empty?: {
        title?: string;
        text: string;
        symbol?: string;
    };
}
/** The card list as one block. Throws a `PluginError` for a button key that is empty or contains a dot. */
export declare function cardList(spec: CardListSpec): Block;
export interface CardListHandlers {
    onOpen?(card: string, event: ViewEvent): unknown;
    /** A card's button: `key` is the button's key. */
    onButton?(card: string, key: string, event: ViewEvent): unknown;
    /** An entry of a card's menu (the "…" or a right-click): `key` is the entry's key. */
    onMenu?(card: string, key: string, event: ViewEvent): unknown;
}
/**
 * Sends the card list's events to `handlers`. Call once. `menuKeys` lists the keys of every menu entry any card can have
 * (an action is routed by its exact text, so each needs registering).
 */
export declare function routeCardList(view: ViewState, options: Pick<CardListSpec, 'id'> & {
    menuKeys?: string[];
}, handlers: CardListHandlers): void;
