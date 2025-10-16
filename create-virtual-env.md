A **virtual environment** lets you isolate dependencies for each Python project so the packages you install don’t affect others.  
Think of it as a tidy sandbox for your code.

---

## 🔧 Prerequisites

1. **Python** installed (version 3.6 or newer).  
2. Confirm your Python installation by running in Command Prompt or PowerShell:

   ```bash
   python --version
   ```
   or, depending on your setup:
   ```bash
   py --version
   ```

---

## 🚀 Create the Virtual Environment

1. Navigate to your project directory:
   ```bash
   cd C:\path\to\your\project
   ```

2. Create a virtual environment using the built-in `venv` module:
   ```bash
   python -m venv venv
   ```
   ➤ Here, `venv` is the name of the folder where the environment files will live  
   (you can choose another name, but `venv` is a common convention).

---

## 🧠 Activate the Virtual Environment

### Using **Command Prompt (cmd)**:
```bash
venv\Scripts\activate
```

### Using **PowerShell**:
```bash
venv\Scripts\Activate.ps1
```

> ⚠️ If you see an error about execution policies:
> ```bash
> Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
> ```
> Then try activating again.

Once activated, you’ll notice a prefix like `(venv)` before the command prompt — that’s how you know the environment is active.

---

## 📦 Installing Packages

While the virtual environment is active, all packages installed via `pip` will stay isolated inside it:

```bash
pip install package-name
```

Example:
```bash
pip install requests
```

---

## 🚪 Deactivating the Virtual Environment

When you’re done working:
```bash
deactivate
```

---

## 🧹 Optional: Removing the Virtual Environment

To recreate or clean up the environment, just delete the folder:
```bash
rmdir /S /Q venv
```

---

## ✅ Optional: Requirements File

To save your project dependencies:
```bash
pip freeze > requirements.txt
```

To reinstall them later:
```bash
pip install -r requirements.txt
```

---

Now you have everything you need to spin up a clean, isolated Python workspace on Windows — a peaceful little ecosystem where your packages can coexist without stepping on each other’s toes.
