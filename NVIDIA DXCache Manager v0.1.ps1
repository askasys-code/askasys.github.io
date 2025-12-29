Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = "NVIDIA DXCache Manager v0.1"
$form.Size = New-Object System.Drawing.Size(800, 600)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)  # Dark background
$form.ForeColor = [System.Drawing.Color]::White  # Light text

# Path Label and TextBox
$pathLabel = New-Object System.Windows.Forms.Label
$pathLabel.Text = "Cache Path:"
$pathLabel.Location = New-Object System.Drawing.Point(10, 10)
$pathLabel.Size = New-Object System.Drawing.Size(80, 20)
$pathLabel.BackColor = [System.Drawing.Color]::Transparent
$pathLabel.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($pathLabel)

$defaultPath = Join-Path $env:LOCALAPPDATA "NVIDIA\DXCache"
$pathTextBox = New-Object System.Windows.Forms.TextBox
$pathTextBox.Text = $defaultPath
$pathTextBox.Location = New-Object System.Drawing.Point(90, 10)
$pathTextBox.Size = New-Object System.Drawing.Size(600, 20)
$pathTextBox.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
$pathTextBox.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($pathTextBox)

# Load Button
$loadButton = New-Object System.Windows.Forms.Button
$loadButton.Text = "Load Files"
$loadButton.Location = New-Object System.Drawing.Point(700, 10)
$loadButton.Size = New-Object System.Drawing.Size(80, 20)
$loadButton.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$loadButton.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($loadButton)

# ListView for Files
$listView = New-Object System.Windows.Forms.ListView
$listView.View = [System.Windows.Forms.View]::Details
$listView.FullRowSelect = $true
$listView.GridLines = $true
$listView.Location = New-Object System.Drawing.Point(10, 40)
$listView.Size = New-Object System.Drawing.Size(770, 400)
$listView.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
$listView.ForeColor = [System.Drawing.Color]::White
$listView.Columns.Add("File Name", 300) | Out-Null
$listView.Columns.Add("Size (MB)", 100) | Out-Null
$listView.Columns.Add("Last Modified", 300) | Out-Null
$form.Controls.Add($listView)

# Total Size Label
$totalLabel = New-Object System.Windows.Forms.Label
$totalLabel.Text = "Total Size: 0 MB"
$totalLabel.Location = New-Object System.Drawing.Point(10, 450)
$totalLabel.Size = New-Object System.Drawing.Size(200, 20)
$totalLabel.BackColor = [System.Drawing.Color]::Transparent
$totalLabel.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($totalLabel)

# Delete Selected Button
$deleteSelectedButton = New-Object System.Windows.Forms.Button
$deleteSelectedButton.Text = "Delete Selected"
$deleteSelectedButton.Location = New-Object System.Drawing.Point(10, 480)
$deleteSelectedButton.Size = New-Object System.Drawing.Size(120, 30)
$deleteSelectedButton.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$deleteSelectedButton.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($deleteSelectedButton)

# Delete All Button
$deleteAllButton = New-Object System.Windows.Forms.Button
$deleteAllButton.Text = "Delete All"
$deleteAllButton.Location = New-Object System.Drawing.Point(140, 480)
$deleteAllButton.Size = New-Object System.Drawing.Size(80, 30)
$deleteAllButton.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
$deleteAllButton.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($deleteAllButton)

# Load Files Event
$loadButton.Add_Click({
    $path = $pathTextBox.Text
    if (-not (Test-Path $path)) {
        [System.Windows.Forms.MessageBox]::Show("Path does not exist!", "Error")
        return
    }
    $files = Get-ChildItem $path -File
    $listView.Items.Clear()
    $totalSize = 0
    foreach ($file in $files) {
        $sizeMB = [math]::Round($file.Length / 1MB, 2)
        $totalSize += $file.Length
        $item = New-Object System.Windows.Forms.ListViewItem($file.Name)
        $item.SubItems.Add($sizeMB.ToString()) | Out-Null
        $item.SubItems.Add($file.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")) | Out-Null
        $item.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
        $item.ForeColor = [System.Drawing.Color]::White
        $listView.Items.Add($item) | Out-Null
    }
    $totalSizeMB = [math]::Round($totalSize / 1MB, 2)
    $totalLabel.Text = "Total Size: $totalSizeMB MB | Files: $($files.Count)"
})

# Delete Selected Event
$deleteSelectedButton.Add_Click({
    $path = $pathTextBox.Text
    foreach ($item in $listView.SelectedItems) {
        $filePath = Join-Path $path $item.Text
        Remove-Item $filePath -Force -ErrorAction SilentlyContinue
        $listView.Items.Remove($item)
    }
    # Update total size after delete
    $loadButton.PerformClick()
})

# Delete All Event
$deleteAllButton.Add_Click({
    $confirm = [System.Windows.Forms.MessageBox]::Show("Delete all files?", "Confirm", [System.Windows.Forms.MessageBoxButtons]::YesNo)
    if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
        $path = $pathTextBox.Text
        Get-ChildItem $path -File | Remove-Item -Force -ErrorAction SilentlyContinue
        $loadButton.PerformClick()
    }
})

$form.ShowDialog() | Out-Null