import { bytes, pct } from "@/lib/format"

// The gem keeps an execution's earliest child records up to
// execution_buffer_bytes and drops the rest, so a truncated trace looks
// complete unless the page says otherwise. `recorded` is what is on the
// page; the dropped ones never reached the database.
export function truncationNotice(
  recorded: number,
  dropped: number,
  droppedBytes: number | null,
): string {
  const total = recorded + dropped
  return `${recorded.toLocaleString()} of ${total.toLocaleString()} child records recorded; ${dropped.toLocaleString()} dropped${droppedBytes ? ` (${bytes(droppedBytes)})` : ""} because this execution's tree outgrew execution_buffer_bytes. The timeline below is the first ${pct(recorded, total)} of it.`
}
