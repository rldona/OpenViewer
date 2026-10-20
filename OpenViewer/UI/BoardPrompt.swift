import UIKit

/// "New Board" and "Add to Board" helpers shared by the sidebar, the grid and the viewer.
enum BoardPrompt {
    static func create(from presenter: UIViewController, then: @escaping (Board) -> Void) {
        let alert = UIAlertController(title: "New Board", message: "A free canvas to arrange references from any folder.",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Name"
            field.text = "Board \(BoardStore.shared.boards.count + 1)"
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak alert] _ in
            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            then(BoardStore.shared.create(named: name.isEmpty ? "Board" : name))
        })
        presenter.present(alert, animated: true)
    }

    /// "Add to Board" submenu: every board plus "New Board…". `urls` is read when an item is chosen.
    static func menu(from presenter: UIViewController, urls: @escaping () -> [URL], onAdded: ((Board) -> Void)? = nil) -> UIMenu {
        var children: [UIMenuElement] = BoardStore.shared.boards.map { board in
            UIAction(title: board.name, subtitle: "\(board.items.count) images", image: UIImage(systemName: "rectangle.on.rectangle.angled")) { _ in
                BoardStore.shared.add(urls(), to: board.id)
                onAdded?(board)
            }
        }
        children.append(UIAction(title: "New Board…", image: UIImage(systemName: "plus")) { [weak presenter] _ in
            guard let presenter else { return }
            create(from: presenter) { board in
                BoardStore.shared.add(urls(), to: board.id)
                onAdded?(board)
            }
        })
        return UIMenu(title: "Add to Board", image: UIImage(systemName: "rectangle.on.rectangle.angled"), children: children)
    }
}
