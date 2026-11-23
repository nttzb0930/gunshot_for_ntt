# Google フォト標準バックアップの転送 (Native Backup Routing)

Gunshot には、Google フォト標準のバックアップ操作を検知し、アップロード先を自動的に GoToHP の Pixel 偽装アップロードへ転送する機能（**Native Backup Routing**）が搭載されています。

この機能を有効化すると、GoToHP の設定画面から写真を手動で選択しなくても、Google フォトアプリ本来のバックアップ機能を通じて自動的に Pixel 偽装によるアップロードが行われます。

---

## 🚀 設定手順

1. **Google フォトを起動**し、ログイン中のアカウントに GoToHP が自動接続されたことを確認します。
2. 画面右上の **プロフィールアイコン →「GoToHP の設定」** を開きます。
3. **「手動・自動バックアップを GoToHP へ送る」** を **ON** にします。
   - ※初期状態は OFF です。
   - ON にすると、現在の送信先アカウントと画質設定が表示されますので確認してください。
4. **Google フォト本体のバックアップ設定**も **ON** になっていることを確認します。
   - Google フォト本来のスケジューラーが写真を検知してアップロード処理を開始するため、アプリ本体のバックアップ設定も有効にしておく必要があります。

---

## 🔄 動作の流れ

Google フォト側でバックアップ操作が行われると、Gunshot がそのリクエストを処理します。

- **手動バックアップ**:
  - 写真の詳細画面にある「今すぐバックアップ」ボタンや、複数選択して「バックアップ」を実行した操作が、自動的に GoToHP のキューに転送されます。
- **自動バックアップ**:
  - 新しく撮影した写真や動画が Google フォトによってバックアップ対象になると、GoToHP のキューに転送されます。
- **バックアップ完了後の反映**:
  - GoToHP によるアップロードが完了すると、Google フォト本体のステータス同期が呼び出され、写真の「バックアップ完了」マーク（雲マークの消去やチェックマーク）が正常に更新されます。

---

## ⚙️ 内部の仕組み

Gunshot は Google フォト内部のアップロード要求クラス（`GMUAssetUploadRequest` や `GMULivePhotoSingleUploadRequest` など）をフックしています。

1. **リクエストの傍受**: Google フォトが写真をサーバーへ送信しようとしたタイミングでリクエストを検知し、PhotoKit から無劣化のフルサイズ写真・動画（Live Photo の場合は静止画と動画のペア）を取り出します。
2. **GoToHP キューへの登録**: 抽出したデータを Go コアの永続キューへ渡し、Pixel 偽装プロファイル（Pixel XL 等）でアップロードをスケジュールします。
3. **二重送信の防止**: Google フォト本来の純正アップロード処理を抑止し、同一メディアの重複送信やストレージ容量の二重消費を防ぎます。
4. **ステータス完了同期**: アップロード完了後、Google フォト純正のフィンガープリント照合・アイテム同期（`fetchData`）をトリガーし、UI 上のバックアップ状態を完了として反映させます。

---

## ⚠️ 環境ごとの注意点

- **サイドロード / 非脱獄（Jailed）環境**:
  - Google フォトがフォアグラウンド（画面上）にある間のみバックアップとアップロードが進行します。
- **脱獄（Jailbreak）環境**:
  - メディアがデーモン (`gotohpd`) のキューへ登録されれば、Google フォトを閉じてもバックグラウンドでアップロードが継続します。
- **アカウントや画質を変更した場合**:
  - GoToHP の設定で送信先アカウントや画質プロファイルを変更した場合は、念のため「手動・自動バックアップを GoToHP へ送る」を一度 OFF にしてから再度 ON にし、送信先が正しく更新されていることを確認してください。

---

## 🔍 トラブルシューティングと診断

標準バックアップからの転送状況を確認したい場合：

1. 「GoToHP の設定」内の **「Upload diagnostics（診断）」** を ON にします。
2. 写真のバックアップを行い、**「Export diagnostics」** をタップして診断情報を書き出します。
3. `backupRouting` 項目内の `intercepted`（傍受数）、`queued`（キュー追加数）、`nativeReconciled`（同期完了数）などの数値が増加していれば、正常に機能しています。

---

## Experimental cloud-only deletion (Google Photos 7.20.2)

An additional choice is presented before the supported native deletion command's
first destructive phase: **Delete only from Google Photos**, **Use normal deletion**,
or **Cancel**. In 7.20.2, the trash UI calls `deleteLocalAssets` before enqueueing
`execute`. Both entry points are intercepted, with separate promises; the choice
is retained on the same command so queued cloud execution does not ask again.
The original local promise result and host queue ordering are preserved. A closing
confirmation is allowed up to two seconds to dismiss; failure rejects the request
without automatically continuing native deletion.
The same command class also handles restoration and permanent deletion from Trash.
Audited `context.mutationOperation` values 2 (restore) and 16/32 (permanent deletion)
bypass the chooser at both entry points and forward the original native result.
In 7.20.2, both deleting selected trash items and emptying Trash pass operation 16;
the command constructor also maps 32 to its permanent-deletion strategy. These
operations retain the host's confirmation, leave persisted local protection and
the PhotoKit guard unchanged, and do not reuse a previous deletion choice.
Selections confirmed to contain only cloud photos use the original native
confirmation without an additional destination chooser. This requires successful
local dedup lookups for every item, no local identities and confirmed cloud media.
Missing/failed lookups remain unresolved; mixed local/cloud selections retain the
chooser before local deletion.
The cloud-only choice requires GoToHP backup integration, resolved backed-up items
and local PhotoKit identities. Unsupported selections disable the cloud-only
choice; they never silently select it. Finish imports and uploads before using it.

Cloud-only deletion persists the selected local identities before the original
Google deletion executes. The local-delete branch receives an empty selection;
the cloud command keeps its original media selection and native promise handling.
A PhotoKit guard also excludes protected assets from later deletion requests in
this Google Photos process. New native GoToHP backup requests and asset exports
reject protected identities. Protection persists across app launches.

The deletion chooser contains only cloud deletion, normal deletion and Cancel.
For fully resolved selections, the normal action is labeled **Delete both copies**
or **Delete from iPhone** when appropriate; mixed/unknown cases retain a generic
normal-deletion label. Choosing normal deletion explicitly removes protection for
the resolved selection, then uses the native deletion behavior.

**GoToHP > Photos kept on this iPhone** opens a dedicated local management page.
It reads an immutable identifier snapshot through `GSLocalPhotoProtection`, loads
available PhotoKit assets on a worker, and requests visible thumbnails without
network downloads. Inaccessible assets retain a placeholder and their saved
protection; absence from a fetch is not treated as proof of deletion. Selected
items can explicitly **Allow backup again**, with confirmation that normal backup
and deletion behavior resumes. This operation changes only protection state,
never deletes media or enqueues uploads. A failed write leaves protection intact.
Do not uninstall the tweak or clear the app's data while relying on protection.
Other devices, Apple Photos/iCloud operations and other apps are outside its scope.
File imports, separate copies with new local IDs and explicit retries of previously
exported jobs are not content-based exclusions and may upload the photo again.

The upload diagnostics JSON includes `cloudOnlyDeletion`: availability/reason,
store health, protected count, unresolved selections and blocked local deletions.
`localPhaseIntercepted` and `executeIntercepted` count first interceptions per
command phase. `executeHookActive` checks whether the installed method still points
to the hook. `choicesShown` counts completed presentations, and `lastOutcome`
reports presentation/account failures without identifying the selected photos.
`lastResolution` distinguishes inaccessible local assets, unavailable store lookups
and other unresolved selections. `nativeLocalResult` and `nativeExecuteResult`
record each phase's pending/succeeded/failed/cancelled status. Failures include only
the numeric error code and a recognized system error domain (otherwise `other`),
never messages, paths, userInfo, account IDs or media IDs. `lastOutcome` also marks
hook validation refusals before a native phase starts. A native success records
the promise result, not independent proof that the item disappeared from the UI.
The existing backup report counts `cloudDeletedAssetBlocked`. Neither section
includes local identities, photo contents or credentials.
The same report includes `cloudOnlyDeletion.protection`: store health, protected
count, upload-block attempts (native backup and asset export), unprotect attempts,
successes, failures, last result and numeric error code. Counters cover this launch;
only protection identities persist. No additional diagnostics screen is added.

This is an experimental implementation based on static IPA inspection. Native
synthetic fixtures cover cancellation, promise forwarding, restoration after a
protection write, simulated deletion sync, queue/account guards, normal deletion
and unsupported contracts. They require macOS; real-device acceptance remains
necessary. Use disposable test photos with another copy, then check Apple Photos
and Google Photos after reopening/syncing and restarting the device. A successful
build or mock test does not establish that all private synchronization paths work.
