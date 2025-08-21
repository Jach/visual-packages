(defsystem "visual-packages"
  :description "GUI for viewing your Lisp packages"
  :author "Jach <jach@thejach.com>"
  :license "Public Domain / Unlicense"
  :depends-on ("bordeaux-threads"
               "cl-cffi-gtk4")
  :components ((:module "src/"
                        :serial t
                        :components ((:file "main")))))

