# focus-reading.lua
# Focus Reading patch for KOReader

Focus Reading is a KOReader patch for EPUB, HTML, and XHTML books. It adds two assistive reading modes under **Typography**, below **Font**: **Bionic Reading** and **Guided Dots**. You can use either mode on its own or enable both at the same time.

For quicker access, it also adds two Reader menu actions:

- `Toggle bionic reading`
- `Toggle guided dots`

When you toggle Focus Reading, KOReader reloads the book automatically and now restores your place much more reliably, keeping you near the same chapter instead of dropping you back somewhere else.

## How to use

1. Put the patch file in `koreader/patches`.
2. Restart KOReader.
3. Open a supported book.
4. Open the book menu.
5. Go to `Typography`.
6. Find `Focus Reading` below `Font`.
7. Use the checkbox to toggle `Bionic Reading`, `Guided Dots`, or both.
8. Or use the Reader menu shortcuts:
   - `Toggle bionic reading`
   - `Toggle guided dots`

## Notes

Works on supported text books only. `Bionic Reading` changes word emphasis. `Guided Dots` adds visual markers to help guide your eyes. If you use hash-based metadata, file rewrites can affect linked progress and other book data.
\
**Bionic Reading**
<img src="https://github.com/user-attachments/assets/386c41cf-cef4-47a3-988e-439b1d87b518" style="width:50%;" />

**Guided Dots**

<img src="https://github.com/user-attachments/assets/9b00362e-7e24-4817-859f-d609b4023843" width="50%" />

**Bionic Reading & Guided Dots**

<img src="https://github.com/user-attachments/assets/f52ba8ea-bb7e-43ee-bbb0-87549b929b08" width="50%" />
