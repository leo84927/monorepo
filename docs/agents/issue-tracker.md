# Issue tracker：GitHub

本 repo 的 issue 與 PRD 都存放在 `leo84927/monorepo` 的 GitHub Issues，一律使用 `gh` CLI 操作。

## 操作慣例

- **建立 issue**：`gh issue create --title "..." --body "..."`。多行內容用 heredoc。
- **讀取 issue**：`gh issue view <number> --comments`，用 `jq` 過濾留言，並一併取得標籤。
- **列出 issue**：`gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'`，視需要加上 `--label` 與 `--state` 過濾。
- **留言**：`gh issue comment <number> --body "..."`
- **新增／移除標籤**：`gh issue edit <number> --add-label "..."` / `--remove-label "..."`
- **關閉**：`gh issue close <number> --comment "..."`

repo 由 `git remote -v` 推斷 —— 在 clone 目錄內執行時 `gh` 會自動判斷。

> **submodule 注意事項。** 各服務目錄（`center/`、`core/`、`exchange_rate/`、`telegram/`、`bookkeeping/`、`docker/`、`scheduler/`）都是獨立的 git submodule，各自對應一個 GitHub repo。在這些目錄內執行 `gh` 會打到**該 submodule 自己的** issue，而不是 monorepo 的。除非任務明確指定要操作某個服務自己的 tracker，否則一律從 monorepo 根目錄執行 `gh`，讓 issue 落在 `leo84927/monorepo`。

## 把 pull request 當作 triage 來源

**PRs as a request surface: no.** _（若本 repo 要把外部 PR 視為功能需求，改成 `yes`；`/triage` 會讀這個旗標。此行為 `/triage` 比對的字面字串，請勿翻譯。）_

設為 `yes` 時，PR 會走與 issue 相同的標籤與狀態流程，改用對應的 `gh pr` 指令：

- **讀取 PR**：`gh pr view <number> --comments`，diff 用 `gh pr diff <number>`。
- **列出待 triage 的外部 PR**：`gh pr list --state open --json number,title,body,labels,author,authorAssociation,comments`，只保留 `authorAssociation` 為 `CONTRIBUTOR`、`FIRST_TIME_CONTRIBUTOR` 或 `NONE` 者（排除 `OWNER`／`MEMBER`／`COLLABORATOR`）。
- **留言／標籤／關閉**：`gh pr comment`、`gh pr edit --add-label`／`--remove-label`、`gh pr close`。

GitHub 的 issue 與 PR 共用同一組編號，因此單獨的 `#42` 可能是任一種 —— 先用 `gh pr view 42` 解析，失敗再退回 `gh issue view 42`。

## 當 skill 說「publish to the issue tracker」

建立一個 GitHub issue。

## 當 skill 說「fetch the relevant ticket」

執行 `gh issue view <number> --comments`。

## Wayfinding operations

（Wayfinder 操作，供 `/wayfinder` 使用。**map** 是單一 issue，其**子 issue** 即為各張 ticket。標題維持英文，因為 `wayfinder` 會按名稱尋找此節。）

- **Map**：一個帶 `wayfinder:map` 標籤的 issue，內容為 Notes／Decisions-so-far／Fog 三段。以 `gh issue create --label wayfinder:map` 建立。
- **子 ticket**：以 GitHub sub-issue 的形式掛在 map 底下（用 `gh api` 呼叫 sub-issues endpoint）。若該 repo 未啟用 sub-issue，就在 map 內文的 task list 加上該子項，並在子 issue 內文開頭寫 `Part of #<map>`。標籤為 `wayfinder:<type>`（`research`／`prototype`／`grilling`／`task`）。一旦被認領，該 ticket 就 assign 給負責推進的開發者。
- **阻塞關係**：使用 GitHub 的**原生 issue dependencies**，這是唯一在 UI 上看得見的標準表示法。以 `gh api --method POST repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>` 建立一條邊，其中 `<blocker-db-id>` 是阻塞方的數字 **database id**（用 `gh api repos/<owner>/<repo>/issues/<n> --jq .id` 取得，**不是** `#number`，也不是 `node_id`）。GitHub 會回報 `issue_dependencies_summary.blocked_by`（只算未關閉的阻塞方，這才是即時的判斷依據）。若無法使用 dependencies，退回在子 issue 內文開頭寫一行 `Blocked by: #<n>, #<n>`。當所有阻塞方都關閉時，該 ticket 即解除阻塞。
- **Frontier 查詢**：列出 map 底下所有未關閉的子項（`gh issue list --state open`，範圍限縮在 map 的 sub-issue／task list），排除仍有未關閉阻塞方者（`issue_dependencies_summary.blocked_by > 0`，或 `Blocked by` 那行仍有未關閉的 issue）以及已有 assignee 者；剩下的依 map 內的排列順序取第一個。
- **認領**：`gh issue edit <n> --add-assignee @me` —— 這是一個 session 的第一個寫入動作。
- **結案**：先 `gh issue comment <n> --body "<answer>"`，再 `gh issue close <n>`，最後把 context 指標（gist 連結）追加到 map 的 Decisions-so-far。
