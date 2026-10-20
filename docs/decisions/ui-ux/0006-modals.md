# Modals sit centred over a dimmed window and own the keyboard

Decided: 2026-10-18
Status: accepted

New session, Rename, Quick Open, and Fan out are centred cards over a 28 % black backdrop; a click on the backdrop or Escape closes them.
While any modal is up, the terminal gives up the keyboard (`AppModel.modalShown`), so typing and Escape never reach an agent.
The first field is focused when the modal opens; Return runs the primary button.
Fields are filled (`ledgerField()`), not outlined; buttons use the `ledger`, `ledgerPrimary`, and `ledgerLink` styles.
