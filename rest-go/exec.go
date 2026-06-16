package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

const maxOutputBytes = 65536

type execResult struct {
	Stdout     string `json:"stdout"`
	Stderr     string `json:"stderr"`
	ExitCode   int    `json:"exitCode"`
	Truncated  bool   `json:"truncated"`
	CWD        string `json:"cwd"`
}

func runSingleLine(line, shell string) execResult {
	command := stringsTrim(line)
	if command == "" {
		return execResult{
			Stderr:   "empty command",
			ExitCode: 1,
			CWD:      defaultCWD(),
		}
	}

	workdir := defaultCWD()
	if st, err := os.Stat(workdir); err != nil || !st.IsDir() {
		return execResult{
			Stderr:   fmt.Sprintf("invalid cwd: %s", workdir),
			ExitCode: 1,
			CWD:      defaultCWD(),
		}
	}

	newCWD, handled, cdErr := applyCDCommand(command, shell, workdir)
	if handled {
		if cdErr != "" {
			return execResult{
				Stderr:   cdErr,
				ExitCode: 1,
				CWD:      workdir,
			}
		}
		if newCWD != "" {
			setSessionCWD(newCWD)
			lower := strings.ToLower(stringsTrim(command))
			if lower == "pwd" || lower == "cwd" || lower == "get-location" || lower == "gl" || lower == "echo %cd%" {
				return execResult{
					Stdout:   newCWD + "\n",
					ExitCode: 0,
					CWD:      newCWD,
				}
			}
			return execResult{ExitCode: 0, CWD: newCWD}
		}
	}

	workdir = defaultCWD()
	var args []string
	if shell == "powershell" {
		args = []string{
			"powershell.exe", "-NoProfile", "-NonInteractive",
			"-Command", command,
		}
	} else {
		args = []string{"cmd.exe", "/d", "/s", "/c", command}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	cmd.Dir = workdir
	hideChildExec(cmd)

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	err := cmd.Run()
	if ctx.Err() == context.DeadlineExceeded {
		return execResult{
			Stderr:   "command timeout (120s)",
			ExitCode: 124,
			CWD:      defaultCWD(),
		}
	}
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			out, outTrunc := trimOutput(stdout.String(), maxOutputBytes)
			errOut, errTrunc := trimOutput(stderr.String(), maxOutputBytes)
			return execResult{
				Stdout:    out,
				Stderr:    errOut,
				ExitCode:  exitErr.ExitCode(),
				Truncated: outTrunc || errTrunc,
				CWD:       defaultCWD(),
			}
		}
		return execResult{
			Stderr:   err.Error(),
			ExitCode: 1,
			CWD:      defaultCWD(),
		}
	}

	out, outTrunc := trimOutput(stdout.String(), maxOutputBytes)
	errOut, errTrunc := trimOutput(stderr.String(), maxOutputBytes)
	return execResult{
		Stdout:    out,
		Stderr:    errOut,
		ExitCode:  0,
		Truncated: outTrunc || errTrunc,
		CWD:       defaultCWD(),
	}
}

func runCommand(command, shell, cwd string) execResult {
	resolveInitialWorkdir(cwd)
	lines := splitCommandLines(command)
	if len(lines) == 0 {
		return execResult{
			Stderr:   "empty command",
			ExitCode: 1,
			CWD:      defaultCWD(),
		}
	}
	if len(lines) == 1 {
		return runSingleLine(lines[0], shell)
	}

	var stdoutParts, stderrParts []string
	exitCode := 0
	truncated := false
	final := defaultCWD()

	for i, line := range lines {
		result := runSingleLine(line, shell)
		if result.CWD != "" {
			final = result.CWD
		}
		exitCode = result.ExitCode
		truncated = truncated || result.Truncated
		if result.Stdout != "" {
			stdoutParts = append(stdoutParts, result.Stdout)
		}
		if result.Stderr != "" {
			stderrParts = append(stderrParts, result.Stderr)
		}
		if exitCode != 0 {
			if i+1 < len(lines) {
				stderrParts = append(stderrParts, fmt.Sprintf("[line %d] command failed, stopped.\n", i+1))
			}
			break
		}
	}

	stdout, outTrunc := trimOutput(strings.Join(stdoutParts, ""), maxOutputBytes)
	stderr, errTrunc := trimOutput(strings.Join(stderrParts, ""), maxOutputBytes)
	return execResult{
		Stdout:    stdout,
		Stderr:    stderr,
		ExitCode:  exitCode,
		Truncated: truncated || outTrunc || errTrunc,
		CWD:       final,
	}
}
