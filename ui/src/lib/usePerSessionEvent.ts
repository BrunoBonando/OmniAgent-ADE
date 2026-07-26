// One subscription per live session id to a per-session Tauri event stream,
// kept in sync as tabs open and close.
//
// This is `App.tsx`'s original `session-attention:{id}` effect, lifted here
// verbatim in behaviour when the second per-session stream
// (`session-status:{id}`, the five-state light) arrived and made it a
// duplicated 30-line dance. Same design decisions as before, unchanged:
//
// - Subscriptions live HERE, not in the component that renders the session.
//   `Terminal.tsx` can subscribe per mounted session because it only cares
//   about its own output; attention badges and status lights are interesting
//   precisely for the session the user is NOT looking at, so they have to be
//   held by whatever owns every tab.
// - The id set is DIFFED, never torn down and rebuilt on each change — a
//   full resubscribe would open a window where a real event lands with
//   nothing listening.
// - The map holds either a resolved `UnlistenFn` or a temporary cancel-flag
//   closure for a subscription still in flight, which is what makes "a tab
//   closed before its `listen()` promise resolved" unsubscribe correctly
//   instead of leaking a listener for a dead session.
import { useEffect, useRef } from "react";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

/**
 * @param ids       every live session id — a new array each render is fine,
 *                  resubscription is keyed off the ids themselves.
 * @param prefix    the event-name prefix, including the colon
 *                  (`"session-status:"`).
 * @param onEvent   called with the id and the event payload. Its identity
 *                  may change every render; it is read through a ref, so a
 *                  changing handler never causes a resubscribe.
 */
export function usePerSessionEvent<T>(
  ids: string[],
  prefix: string,
  onEvent: (id: string, payload: T) => void,
): void {
  const handlerRef = useRef(onEvent);
  useEffect(() => {
    handlerRef.current = onEvent;
  });

  const listeners = useRef<Map<string, UnlistenFn>>(new Map());
  // `ids` is a fresh array almost every render; the subscription set only
  // needs to change when the ids themselves do. NUL-joined so no id can
  // forge a boundary.
  const key = ids.join("\u0000");

  useEffect(() => {
    const map = listeners.current;
    const live = new Set(key.length > 0 ? key.split("\u0000") : []);

    for (const [id, unlisten] of map) {
      if (!live.has(id)) {
        unlisten();
        map.delete(id);
      }
    }

    for (const id of live) {
      if (map.has(id)) continue;
      let cancelled = false;
      map.set(id, () => {
        cancelled = true;
      });
      void listen<T>(`${prefix}${id}`, (event) => handlerRef.current(id, event.payload)).then((unlisten) => {
        if (cancelled) {
          unlisten();
          return;
        }
        map.set(id, unlisten);
      });
    }
  }, [key, prefix]);

  // Unsubscribe everything on unmount. Its own effect (rather than a cleanup
  // on the one above) so it runs only when the owner really goes away, not
  // on every id-set change.
  useEffect(() => {
    const map = listeners.current;
    return () => {
      for (const unlisten of map.values()) unlisten();
      map.clear();
    };
  }, []);
}
