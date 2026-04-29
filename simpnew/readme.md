| Aspect         | v1 (previous)           | v2 (this)                                       |
| -------------- | ----------------------- | ----------------------------------------------- |
| Page logic     | JS view.extend({})      | Lua .htm template + controller                  |
| HTTP polling   | fs.exec_direct via rpcd | XHR.get → Lua action_list() (same as halsamrec) |
| rpcd ACL       | Required                | Not needed                                      |
| luci-compat    | Not needed (JS only)    | Required on 21.02+ (same as halsamrec)          |
| Files deployed | 4                       | 4 (same count, different stack)                 |
| Works on 19.07 | No                      | Yes                                             |
