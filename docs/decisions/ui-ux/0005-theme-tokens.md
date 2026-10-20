# Colours come only from the Ledger tokens

Decided: 2026-10-18
Status: accepted

Every colour in a view comes from `Ledger` in `app/Sources/HubApp/Theme.swift`, each with a light and a dark value; views never use raw hex.
New colours are added there as tokens first.
Secondary text uses `Ledger.ink2`, tertiary `Ledger.ink3`, chosen for contrast on both paper and desk.
The window follows the terminal theme by default (ADR 0007).
