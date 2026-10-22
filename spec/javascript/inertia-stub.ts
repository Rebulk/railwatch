// Stands in for "@inertiajs/react", which a host has and this repository does
// not. Each test replaces it with vi.mock; this only lets the import resolve.
export const router = { on: () => () => undefined }
