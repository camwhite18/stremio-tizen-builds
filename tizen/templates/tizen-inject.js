/**
 * tizen-inject.js — Samsung TV integration for Stremio Web
 *
 * Injected into stremio-web source builds to add:
 * - TV remote key handling (back, exit, media keys)
 * - Tizen lifecycle management
 * - Samsung TV input device registration
 */
(function() {
    'use strict';

    // ── Register Samsung TV remote keys ─────────────────────────────────
    try {
        var keys = [
            'MediaPlayPause', 'MediaPlay', 'MediaPause',
            'MediaStop', 'MediaRewind', 'MediaFastForward',
            'MediaTrackPrevious', 'MediaTrackNext',
            'ColorF0Red', 'ColorF1Green', 'ColorF2Yellow', 'ColorF3Blue',
            'Info', 'Guide'
        ];
        keys.forEach(function(key) {
            try { tizen.tvinputdevice.registerKey(key); } catch(e) {}
        });
    } catch(e) {
        // Not running on Tizen — silently ignore
    }

    // ── Back / Exit key handling ────────────────────────────────────────
    var KEY_BACK = 10009;
    var KEY_EXIT = 10182;

    document.addEventListener('keydown', function(e) {
        if (e.keyCode === KEY_EXIT) {
            e.preventDefault();
            try { tizen.application.getCurrentApplication().exit(); } catch(ex) {}
        }
    });

    // ── Visibility change (TV sleep / wake) ─────────────────────────────
    document.addEventListener('visibilitychange', function() {
        if (document.hidden) {
            // TV went to sleep — pause any playing media
            var videos = document.querySelectorAll('video');
            videos.forEach(function(v) { v.pause(); });
        }
    });

    // ── Prevent context menu on long press ──────────────────────────────
    document.addEventListener('contextmenu', function(e) {
        e.preventDefault();
    });

    console.log('[Stremio Tizen] TV integration loaded');
})();
