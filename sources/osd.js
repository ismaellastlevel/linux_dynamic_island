import Gio from 'gi://Gio';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';

// OSD manager methods to patch, each with a function returning its [icon, label, level] arguments.
// GNOME 46 has show(monitorIndex, icon, label, level, maxLevel). Newer GNOME (50) moved that to showOne()
// (per monitor, brightness) and added showAll(icon, label, level, maxLevel) (volume); its show() is internal.
function osdMethods(osd) {
    if (osd.showAll)
        return {showOne: args => args.slice(1), showAll: args => args};
    return {show: args => args.slice(1)};
}

// Shows volume and brightness changes on the island instead of the shell's OSD pop-up.
// The OSD manager is only patched while "show-volume" is on, and any failure falls back
// to the shell's own OSD so a changed signature can't take the shell down.
export class OsdSource {
    constructor(island, settings) {
        this._island = island;
        this._settings = settings;
        this._originals = null;
        this._settings.connectObject('changed::show-volume', () => this._sync(), this);
        this._sync();
    }

    _sync() {
        if (this._settings.get_boolean('show-volume'))
            this._patch();
        else
            this._unpatch();
    }

    _patch() {
        if (this._originals)
            return;
        const osd = Main.osdWindowManager;
        this._originals = {};
        for (const [name, unpack] of Object.entries(osdMethods(osd))) {
            const original = osd[name];
            this._originals[name] = original;
            osd[name] = (...args) => {
                try {
                    const [icon, label, level] = unpack(args);
                    if (typeof icon !== 'string' && !(icon instanceof Gio.Icon))
                        throw new Error(`unexpected icon ${icon}`);
                    const hasLevel = Number.isFinite(level);
                    this._island.toast(icon, hasLevel ? '' : String(label ?? ''), {level: hasLevel ? level : null, duration: 1500});
                } catch (e) {
                    console.warn(`Dynamic Island: OSD integration failed, using the shell OSD: ${e}`);
                    original.apply(osd, args);
                }
            };
        }
    }

    _unpatch() {
        if (!this._originals)
            return;
        // The patches are own properties, deleting them brings back the shell's methods
        for (const name in this._originals)
            delete Main.osdWindowManager[name];
        this._originals = null;
    }

    destroy() {
        this._settings.disconnectObject(this);
        this._unpatch();
        this._island = null;
        this._settings = null;
    }
}
