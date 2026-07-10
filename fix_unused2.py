import re

path = '/Users/castromurugan/Documents/Blackforest/blackforest_app/lib/waiter_call_table_range_page.dart'
with open(path, 'r') as f:
    content = f.read()

# Fix setState blocks
content = content.replace(
'''      setState(() {
        _isLoading = true;
        _errorMessage = null;
        _userKey = userKey;
        _candidateKeys = candidateKeys;
      });''',
'''      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });'''
)

content = content.replace(
'''      setState(() {
        _branchId = branchId;
        _branchName = branchName;
        _sections = sections;
        _isLoading = false;
      });''',
'''      setState(() {
        _branchName = branchName;
        _sections = sections;
        _isLoading = false;
      });'''
)

# Remove _statusAccentColor
content = re.sub(
    r'  Color _statusAccentColor\(_TableCellViewModel table\) \{.*?\n  \}\n\n  Widget _buildTableTile',
    '  Widget _buildTableTile',
    content,
    flags=re.DOTALL
)

with open(path, 'w') as f:
    f.write(content)
print("Done")
