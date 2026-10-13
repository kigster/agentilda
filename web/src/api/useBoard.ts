import { useEffect, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import type { Board, Snapshot } from "./types";
import { fetchBoard, isFixtureMode, loadFixtureBoard } from "./client";
import { openStream, type ConnectionState } from "./events";
import { BOARD_KEY } from "./queryClient";
import { replies } from "./replies";

export type { ConnectionState } from "./events";

const newer = (old: Snapshot | undefined, next: Snapshot): Snapshot => (old && old.seq >= next.seq ? old : next);

/**
 * Reconciles two boards node by node: no node's snapshot is ever replaced by one with a lower `seq`. A GET that left
 * before a streamed snapshot and lands after it would otherwise roll the board back. Nodes absent from `next` have
 * left (their snapshot key expired), so they go.
 */
export function reconcile(old: Board | undefined, next: Board): Board {
  if (!old) return next;
  const me = old.me.node.id === next.me.node.id ? newer(old.me, next.me) : next.me;
  const was = new Map(old.others.map(s => [s.node.id, s]));
  const others = next.others.map(s => newer(was.get(s.node.id), s));
  if (me === old.me && others.length === old.others.length && others.every((s, i) => s === old.others[i])) return old;
  return { me, others };
}

export interface BoardState {
  board: Board | undefined;
  /** The first GET /api/board has not answered yet. */
  isLoading: boolean;
  error: Error | null;
  connection: ConnectionState;
  /** True under `?fixture`: the board is the sample file and nothing is live. */
  fixture: boolean;
}

/**
 * The page's whole state. TanStack Query holds the Board, first from `GET /api/board`, then from every `event: board`
 * on the stream; replies on the stream go to the reply bus, where useSendCommand waits for them.
 *
 * Call it once, at the top of the page: each call opens its own stream.
 */
export function useBoard(): BoardState {
  const fixture = isFixtureMode();
  const client = useQueryClient();
  const [connection, setConnection] = useState<ConnectionState>(fixture ? "live" : "reconnecting");
  const query = useQuery({
    queryKey: BOARD_KEY,
    queryFn: fixture ? () => Promise.resolve(loadFixtureBoard()) : fetchBoard,
    // A fetched board is reconciled with what the stream already delivered, never laid over it.
    structuralSharing: (old: unknown, next: unknown) => reconcile(old as Board | undefined, next as Board),
  });

  useEffect(() => {
    if (fixture) return;
    return openStream({
      onBoard: board => client.setQueryData<Board>(BOARD_KEY, old => reconcile(old, board)),
      onReply: reply => replies.deliver(reply),
      onState: setConnection,
      onReconnect: () => void client.refetchQueries({ queryKey: BOARD_KEY }),
    });
  }, [client, fixture]);

  return { board: query.data, isLoading: query.isPending, error: query.error, connection, fixture };
}
