import { useEffect, useMemo, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import type { Board, Snapshot } from "./types";
import { fetchBoard, isFixtureMode, loadFixtureBoard } from "./client";
import { openStream, type ConnectionState } from "./events";
import { BOARD_KEY } from "./queryClient";
import { replies } from "./replies";

export type { ConnectionState } from "./events";

/**
 * A board as `GET /api/board` and the stream deliver it. `me` is null until this machine's engine first publishes
 * (`tilda web` started before `tilda run`, or the run's snapshot expired), so the page never assumes it is there.
 */
export interface WireBoard {
  me: Snapshot | null;
  others: Snapshot[];
}

const newer = (old: Snapshot | undefined, next: Snapshot): Snapshot => (old && old.seq >= next.seq ? old : next);

/**
 * Reconciles two boards node by node: no node's snapshot is ever replaced by one with a lower `seq`. A GET that left
 * before a streamed snapshot and lands after it would otherwise roll the board back. Nodes absent from `next` have
 * left (their snapshot key expired), so they go.
 */
export function reconcile(old: WireBoard | undefined, next: WireBoard): WireBoard {
  if (!old) return next;
  const me = old.me && next.me && old.me.node.id === next.me.node.id ? newer(old.me, next.me) : next.me;
  const was = new Map(old.others.map(s => [s.node.id, s]));
  const others = next.others.map(s => newer(was.get(s.node.id), s));
  if (me === old.me && others.length === old.others.length && others.every((s, i) => s === old.others[i])) return old;
  return { me, others };
}

export interface BoardState {
  board: Board | undefined;
  /** The first GET /api/board has not answered yet. */
  isLoading: boolean;
  /** The server answered, but this machine's engine has not published a snapshot yet: `board` stays undefined. */
  waiting: boolean;
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
  const query = useQuery<WireBoard>({
    queryKey: BOARD_KEY,
    queryFn: fixture ? () => Promise.resolve(loadFixtureBoard()) : fetchBoard,
    // A fetched board is reconciled with what the stream already delivered, never laid over it.
    structuralSharing: (old: unknown, next: unknown) => reconcile(old as WireBoard | undefined, next as WireBoard),
  });

  useEffect(() => {
    if (fixture) return;
    return openStream({
      onBoard: board => client.setQueryData<WireBoard>(BOARD_KEY, old => reconcile(old, board)),
      onReply: reply => replies.deliver(reply),
      onState: setConnection,
      onReconnect: () => void client.refetchQueries({ queryKey: BOARD_KEY }),
    });
  }, [client, fixture]);

  const data = query.data;
  // The page below works on a Board whose `me` is there; until it is, there is no board to show.
  const board = useMemo<Board | undefined>(() => (data?.me ? { me: data.me, others: data.others } : undefined), [data]);
  return { board, isLoading: query.isPending, waiting: !!data && !data.me, error: query.error, connection, fixture };
}
