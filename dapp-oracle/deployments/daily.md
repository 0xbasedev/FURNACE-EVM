---
name: Crucible daily brief
agent: ../agents/crucible.md
environment_id: ../environments/cloud.yaml
resources:
  - type: memory_store
    memory_store_id: ../memory_stores/ideas.yaml
    access: read_write
    instructions: Past ideas and the user's taste. Read all of it before researching; write the new idea here before finishing.
schedule:
  type: cron
  expression: "0 10 * * *"
  timezone: America/New_York
initial_events:
  - type: user.define_outcome
    description: Research the current Solana ecosystem at length, then produce today's dapp brief at /mnt/session/outputs/brief.md, pressure-tested by Critic, Whale, and Degen, and record the idea in memory.
    max_iterations: 4
    rubric:
      type: text
      content: |
        # STARTER RUBRIC - tune this
        1. /mnt/session/outputs/brief.md exists and names one specific dapp concept with a one-sentence thesis.
        2. It cites at least 5 distinct source links, all from research done in this session.
        3. It contains a tokenomics section with concrete numbers (total supply, emission or unlock schedule, value sinks and sources).
        4. A simulation script and its output for those tokenomics numbers exist in /mnt/session/outputs/.
        5. It contains a tool-stack table (layer, tool, why, source link); every tool was verified live this session.
        6. It contains an "EVM port" section mapping Solana components to Solidity/Foundry/OpenZeppelin equivalents with current doc links.
        7. It includes the three strongest objections from Critic, Whale, and Degen, each with a rebuttal.
        8. It includes a revenue model, kill criteria, and a one-weekend MVP scope.
        9. It includes interface principles that steer users toward good decisions and discourage bad ones.
        10. The idea is not a duplicate of any idea in the memory store, and a new entry was written to memory.
---
