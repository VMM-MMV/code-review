# Copyright 2024 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import os
import subprocess
import ast

def is_ascii_text(file_path):
    """
    Check if the file contains ASCII text.
    :param file_path: Path to the file
    :return: Boolean indicating whether the file contains ASCII text
    """
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            f.read()
        return True
    except UnicodeDecodeError:
        return False

def get_text_files_contents(path, ignore=None):
    """
    Returns a dictionary with file paths (including file name) as keys 
    and the respective file contents as values.
    :param path: Directory path
    :param ignore: List of file or folder names to be ignored
    :return: Dictionary with file paths as keys and file contents as values
    """
    if ignore is None:
        ignore = set(['venv', '__pycache__', '.gitignore'])

    result = {}
    for dirpath, dirnames, filenames in os.walk(path):
        # Remove ignored directories from dirnames so os.walk will skip them
        dirnames[:] = [dirname for dirname in dirnames if dirname not in ignore]

        for filename in filenames:
            if filename not in ignore:
                full_path = os.path.join(dirpath, filename)
                if is_ascii_text(full_path):
                    with open(full_path, 'r', encoding='ascii') as f:
                        result[full_path] = f.read()
    return result


def format_files_as_string(contexts): # Renamed input to contexts for clarity as per user goal
    def process_file(file_path):
        if not is_ascii_text(file_path):
            return f"file: {file_path}\nsource: [Binary File - Not ASCII Text]\n"
        try:
            with open(file_path, 'r', encoding='utf-8') as file: # Added encoding for robustness
                content = file.read()
                return f"\nfile: {file_path}\ncontent:\n{content}\n"
        except Exception as e:
            # Handle potential file reading errors
            print(f"Error reading file {file_path}: {e}")
            return f"file: {file_path}\nsource: [Error reading file: {e}]\n"


    formatted_string = ""
    exclude_directories = set(['venv', '__pycache__', '.gitignore'])

    # --- New Logic: Check and Transform String Input ---
    if isinstance(contexts, str):
        print(f"DEBUG: Initial input is a string: '{contexts}'")
        # Check if the string looks like a list literal
        # Use strip() to handle potential leading/trailing whitespace
        if contexts.strip().startswith('[') and contexts.strip().endswith(']'):
            print(f"DEBUG: String looks like a list literal. Attempting evaluation...")
            try:
                # Safely evaluate the string
                evaluated_object = ast.literal_eval(contexts)

                # If the evaluation result is actually a list, reassign contexts
                if isinstance(evaluated_object, list):
                    print("DEBUG: String successfully evaluated to a list. Proceeding with list handling.")
                    contexts = evaluated_object # *** Reassign contexts to the actual list ***
                else:
                     # Handle cases where the string was "[123]" -> 123 (not a list)
                     print(f"DEBUG: String evaluated but result was not a list ({type(evaluated_object)}). Falling through to string handling.")
                     # contexts remains the original string, will be handled below
                     pass
            except (ValueError, SyntaxError) as e:
                # Handle cases where the string looks like '[]' but isn't valid literal Python inside
                print(f"DEBUG: String looks like a list but failed literal evaluation: {e}. Falling through to string handling.")
                # contexts remains the original string, will be handled below
                pass # Fall through to the string handling logic below
        else:
            print(f"DEBUG: String does not look like a list literal. Falling through to string handling.")
            # contexts remains the original string, will be handled below
            pass # Fall through to the string handling logic below
    # --- End New Logic ---

    # --- Original Logic, now handling potentially transformed 'contexts' ---

    if isinstance(contexts, str): # This branch is taken if input was originally a string OR failed list transformation
        print(f"DEBUG: Handling input as a single file/directory path: '{contexts}'")
        # Original string handling logic
        if os.path.isdir(contexts):
            # print(f"DEBUG: '{contexts}' is a directory. Walking...")
            for root, dirs, files in os.walk(contexts):
                dirs[:] = [d for d in dirs if d not in exclude_directories]
                files[:] = [f for f in files if f not in exclude_directories]
                for file in files:
                    file_path = os.path.join(root, file)
                    # print(f"DEBUG: Checking file: {file_path}")
                    if os.path.exists(file_path):
                        # print(f"DEBUG: Processing file: {file_path}")
                        formatted_string += process_file(file_path)
        else:
             # print(f"DEBUG: '{contexts}' is a file. Processing...")
             if os.path.exists(contexts):
                formatted_string += process_file(contexts)
             else:
                print(f"DEBUG: Warning: Single file/directory not found: '{contexts}'") # Added warning for non-existent paths


    elif isinstance(contexts, list): # This branch is taken if input was originally a list OR successfully transformed from a string
        print(f"DEBUG: Handling input as a list of file paths.")
        # Original list handling logic
        for file_path in contexts:
            # It's good practice to ensure list elements are strings if expected
            if isinstance(file_path, str):
                if os.path.exists(file_path):
                    # print(f"DEBUG: Processing file from list: {file_path}")
                    formatted_string += process_file(file_path)
                else:
                     print(f"DEBUG: Warning: File from list not found: '{file_path}'") # Added warning
            else:
                print(f"DEBUG: Warning: List contains a non-string item: '{file_path}' ({type(file_path)}). Skipping.")


    else:
        # This branch is taken if input was neither string nor list initially
        raise ValueError(f"Input must be a directory path, a single file path, or a list of file paths. Received invalid type: {type(contexts)}")

    return formatted_string

def list_files(start_sha, end_sha, refer_commit_parent=False):

    if refer_commit_parent:
        start_sha = f"{start_sha}^"
        
    command = ["git", "diff", "--name-only", start_sha, end_sha]

    return run_git_command(command)

def list_changes(start_sha, end_sha, refer_commit_parent=False):
    if refer_commit_parent:
        start_sha = f"{start_sha}^"

    command = ["git", "diff", start_sha, end_sha]
    output = subprocess.check_output(command, text=True)
    return output

def list_commit_messages(start_sha, end_sha, refer_commit_parent=False):
    
    command = ["git", "log", "--pretty=format:%s", "--name-only", start_sha, end_sha]
    if refer_commit_parent:
        command = ["git", "log", "--pretty=format:%s", "--name-only", f"{start_sha}^..{end_sha}"]

    output = subprocess.check_output(command, text=True)
    return output

def list_commits_for_branches(branch_a, branch_b):
    command = ["git", "log", "--pretty=format:%h", f"{branch_a}..{branch_b}"]
    return run_git_command(command)

def list_commits_for_tags(tag_a, tag_b):
    command = ["git", "log", "--pretty=format:%h", tag_a, tag_b]
    return run_git_command(command)

def list_tags():
    command = ["git", "tag"]
    return run_git_command(command)

def run_git_command(command):
    output = subprocess.check_output(command).decode("utf-8").strip()
    records = output.splitlines()

    list = []
    for record in records:
        list.append(record)

    return list
