"""Minimal MPRIS player on the session bus, so the island has something to show.

Usage: python3 mock_mpris.py "Track title" "Artist" [--window]
--window also opens two windows like a browser: the track's tab and another tab.
"""
import sys

import gi
from gi.repository import Gio, GLib

TITLE, ARTIST = sys.argv[1], sys.argv[2]

XML = """
<node>
  <interface name="org.mpris.MediaPlayer2">
    <method name="Raise"/>
    <property name="Identity" type="s" access="read"/>
    <property name="CanRaise" type="b" access="read"/>
  </interface>
  <interface name="org.mpris.MediaPlayer2.Player">
    <method name="PlayPause"/>
    <method name="Next"/>
    <method name="Previous"/>
    <property name="PlaybackStatus" type="s" access="read"/>
    <property name="Metadata" type="a{sv}" access="read"/>
    <property name="CanPlay" type="b" access="read"/>
    <property name="CanPause" type="b" access="read"/>
    <property name="CanGoNext" type="b" access="read"/>
    <property name="CanGoPrevious" type="b" access="read"/>
  </interface>
</node>
"""

PROPS = {
    'Identity': GLib.Variant('s', 'Mock Player'),
    'CanRaise': GLib.Variant('b', False),
    'PlaybackStatus': GLib.Variant('s', 'Playing'),
    'Metadata': GLib.Variant('a{sv}', {
        'mpris:trackid': GLib.Variant('o', '/mock/track/1'),
        'xesam:title': GLib.Variant('s', TITLE),
        'xesam:artist': GLib.Variant('as', [ARTIST]),
    }),
    'CanPlay': GLib.Variant('b', True),
    'CanPause': GLib.Variant('b', True),
    'CanGoNext': GLib.Variant('b', True),
    'CanGoPrevious': GLib.Variant('b', True),
}


def on_bus(connection, _name):
    for iface in Gio.DBusNodeInfo.new_for_xml(XML).interfaces:
        connection.register_object('/org/mpris/MediaPlayer2', iface,
                                   lambda *a: a[-1].return_value(None),
                                   lambda c, s, p, i, prop: PROPS[prop],
                                   None)


Gio.bus_own_name(Gio.BusType.SESSION, 'org.mpris.MediaPlayer2.mock',
                 Gio.BusNameOwnerFlags.NONE, on_bus, None, None)
if '--window' in sys.argv:
    gi.require_version('Gtk', '4.0')
    from gi.repository import Gtk
    Gtk.init()
    windows = [Gtk.Window(title=t) for t in (f'{TITLE} - Mock Browser', 'Other tab - Mock Browser')]
    for w in windows:
        w.present()
GLib.MainLoop().run()
