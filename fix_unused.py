import re

path = '/Users/castromurugan/Documents/Blackforest/blackforest_app/lib/waiter_call_table_range_page.dart'
with open(path, 'r') as f:
    content = f.read()

# Remove unused fields
content = re.sub(r'  bool _isSaving = false;\n', '', content)
content = re.sub(r'  String _branchId = \'\';\n', '', content)
content = re.sub(r'  String _userKey = \'\';\n', '', content)
content = re.sub(r'  List<String> _candidateKeys = const <String>\[\];\n', '', content)

# Remove unused _tableKey method
content = re.sub(r'  String _tableKey\(String sectionKey, int tableNumber\) \{\n    return \'\$sectionKey\|\$tableNumber\';\n  \}\n', '', content)

# Remove accentColor
content = content.replace(
'''  Widget _buildTableTile(_TableCellViewModel table) {
    final accentColor = _statusAccentColor(table);
    final subtitle = table.servedBy.isEmpty ? null : table.servedBy;''',
'''  Widget _buildTableTile(_TableCellViewModel table) {
    final subtitle = table.servedBy.isEmpty ? null : table.servedBy;'''
)

with open(path, 'w') as f:
    f.write(content)
print("Done")
