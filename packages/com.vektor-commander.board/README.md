# Board

Kanban boards for each workspace, right in Vektor's sidebar. Plan work in columns, keep tasks with tags, notes and comments, and keep the boards locally or share them through one of your connections.

## Getting started

1. Click **Board** under **Plugins** in the sidebar.
2. Click **New Board…** and give it a name. A new board starts with four columns: Backlog, In Progress, Review and Done.
3. Click **Add task**, or the **+** at the top of a column, to add a task.

Each workspace has its own boards. They are listed under **Board** in the sidebar; click one to open it. Right-click a board there to rename or delete it; right-click **Board** itself to make a new one. The picker above the board switches between the workspace's boards too.

## Working with tasks

- **Move a task** by dragging it by its handle to another place or column, or select it and press **⌥** with the arrow keys.
- **Rename a task** in place: select it and press **Return**.
- **Mark it done** with the circle on the card, or select it and press **Space**.
- **Open a task** to edit its title, column, tags and description. The description is Markdown. **⌘Return** saves.
- **Comments** read like a chat: yours on the right, everyone else's on the left, the newest at the bottom. Type in the box at the bottom and press **Send** or **⌘Return**. You can delete your own comments.

## Finding tasks

- **All tasks** shows every task, only open ones, or only done ones.
- **Tags** shows only tasks with the tags you tick.
- **Search** finds tasks by their title, description and tags: type, then press **Return**.
- **Board** and **List** switch between columns and a sortable list. In the list you can select several tasks and delete them at once.

## Columns and tags

The **…** of a column renames it, changes its colour, moves it or deletes it. Deleting a column asks what to do with its tasks. **Board settings** (the **…** beside Board and List) edits all columns, the tags and the board's name in one place. Colours follow your Vektor theme.

## Where your boards are kept

Without any setup, a workspace's boards stay local, in the plugin's own folder.

To keep them somewhere else, choose a **Boards folder** in the plugin's settings:

- **A local folder**: every change is written there at once.
- **A folder on one of the workspace's connections** (S3, SFTP, SMB…): every change is saved locally at once and synced by itself a few seconds later, and everyone else's changes are brought in every two minutes. **Sync** does it right away. Several people, or one person on several computers, can share one board this way.

The plugin uses the connection you already set up in Vektor. It never sees its address or password.

The boards are plain JSON files, so they stay readable outside Vektor and can be backed up like any other folder.

## When both sides changed the same thing

Sync merges changes task by task and comment by comment, so people editing different tasks, or commenting on the same one, never get in each other's way. When your copy and the shared folder changed the **same** task differently, Sync asks you instead of guessing. It shows both versions side by side, and you choose **Keep Your Version**, **Keep the Place's Version** or **Keep Both**. Nothing is overwritten until you answer.

If a sync is interrupted (Vektor quit, the connection dropped), the next sync finishes it. While the place cannot be reached, Board tries again less and less often, up to every 30 minutes; your changes stay saved locally meanwhile. While a question is open, Board waits for your answer before syncing again.
