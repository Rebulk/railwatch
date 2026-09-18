import { type Consumer, createConsumer } from "@rails/actioncable"

let consumer: Consumer | undefined

// One ActionCable consumer (one WebSocket) shared by the whole app, opened
// lazily on first subscription rather than on every page load.
export function getConsumer(): Consumer {
  consumer ??= createConsumer()
  return consumer
}
