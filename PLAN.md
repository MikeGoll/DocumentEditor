## DocumentViewer

### Overview

The application is a document viewer that allows a user to open a document and have a place for the document to render ("Document Viewer") as well as a chat to be able to connect to an AI service such that the user can chat with the AI about the document, as well as leave comments for the AI to address.

An AI agent (LLM) should be able to work on the file while the user is still reading, adding comments, or making adjustments themselves to the document in order to increase efficiency over other already available solutions such as using LibreOffice or Microsoft Word to make comments, edits, etc and *then* have the AI address comments, only to have to re-open the document. This application should allow the document to remain open the whole time and update in real-time to edits made by either the user or the LLM/AI.

### Technology
This section represents the technology that will be used to create this applcation.

#### Stack
The proposed techical stack for this application is to use `Flutter` to take advantage of its cross-platform performance and maintainability. Files that are processed will be processed  locally and are not uploaded to any cloud, database, etc.

#### Platforms
The supported platforms of the system need to be:
* Windows
* Macintosh
* Linux

### Design
The design of the application should be minimalist and streamlined without crowding the user with too many options or extra, unneeded features.

#### User Interface
The user interface of the application should be a simple column-style layout where the document viewer is on the left-hand side and the AI / agent chat window is on the right-hand side. Any document editing controls (buttons for bold, italics, etc) should sit at the top of the document viewer portion of the user interface.

#### Dynamic Sizing / Responsive Layout
The user interface will need to be dynamically resized when screen sizes are too narrow to support side-by-side configuration of the windows for document viewing and agent chat.

When a screen is too narrow to support the side-by-side configuration, the agent window should be collapsed and a button should appear to expand the chat. The chat portion would render overtop of the document viewer.

#### Comments
Comments should be annotated within the document by showing a hovering icon around a selection made that the comment envelops. When the user hovers over the selection, it should show the comment that was left.

#### Edits
Edits made by the AI should be displayed as in-line. The original selection that is being replaced should have a line through it with two buttons next to the edit. One to accept the edit, and one to deny the edit. When an edit is accepted, the strikethrough selection should be deleted from the document. When an edit is denied, the edit made by the AI should be deleted and the strikethrough selection should no longer display as a strikethrough

### Functionality
The overall funtionality of the app is described in the `Overview` section. However, some other key aspect are needed to keep in mind.

#### Keyboard Shortcuts
The application should allow most basic, common keyboard shortcuts for document editings. Some of the keyboard shortcuts that should be included are:
* CTRL + B = Bold toggle
* CTRL + C = Copy selection 
* CTRL + A = Select all
* CTRL + I = Italics toggle
* CTRL + U = Underline toggle
* CTRL + S = Save / write document
* CTRL + Z = Undo
* CTRL + SHIFT + Z = Redo

##### Macintosh
When on Macintosh, keyboard shortcuts should be modified to use `CMD` instead of `CTRL`.

#### Document Formats
The application should be able to render, annotate, and process documents using the following file formats:
* Text (.txt)
* Microsoft Word (.docx)
* Markdown (.md)

Documents should also be able to be saved / exported in whichever supported file format the user requests and conversions between all support formats should be included.

#### Comments
Comments should be created by having a user select a portion of the document and then selecting a "Create Comment" button, or by using a keyboard shortcut. This will float a textbox where the selection was made for the user to be able to type their comment in. Once the comment has been completed, the user will click on the "Create" button to finalize their comment.

#### Translation Table
A custom "Translation Table" should be able to be specified by the user if documents contain certain phrases or other words (names, etc) that are commonly misspelled. This table will be injected into the overall system prompt fed to the agent when a new session begins in order for the agent to be able to make the changes, or to not repeat the same mistakes.
 
### Agent
An LLM agent should be able to be used by the user to aid in the writing of the document. The LLM agent is not required for the application to still be used as a document processor. LLM agents should be able to see the document, the comments left by a user, as well as respond to the user in the chat window.

#### Providers
The list of providers that the application should support are:
* Local (OpenAI-style API endpoints)
* Anthropic (Claude models)
* OpenAI (ChatGPT models)
* Google (Gemini models)

Each provider will require authentication to be performed from within the application to allow the chat to interact with those services.

#### Agent Chat
The agent chat should be able to be used by the user in order to direct, inform, or ask the LLM agent questions about the document, to create edits, or to resolve comments. The chat is the most important way for a user to interact with the LLM agent in order to provide any necessary context about the document or about the environment in which the agent needs to conduct itself. 

#### Chat History
Chat history is stored locally on the device in a separate directory. Each chat session should be saved as a JSON file that saves chats sequentially between the user and the agent. A button should be available to reset the chat whenever the user wants or needs to.

##### System Prompt
The agent's systme prompt fed by the application should highlight that the agent is an assistant document author and is helping the user with their document. It should inform the AI to stick directly to the content's of the document and not to try to explore any other documents or files on the user's computer.

#### Tools
Tools need to be developed and provided to the agent in order for it to be able to perform certain actions surrounding document manipulation such as reading and writing. It should also allow the agent to read other supporting files if th user requests that they do so.

#### Resolving Comments
When an LLM agent resolves a comment, the comment should be deleted / removed to prevent an issue where comment status is ambiguous.
