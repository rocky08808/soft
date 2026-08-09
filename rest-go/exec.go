package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
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
	args := shellExecArgs(shell, command)

	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	cmd.Dir = workdir
	hideChildExec(cmd)

	stdoutText, stderrText, err := runHiddenCommand(cmd)
	if ctx.Err() == context.DeadlineExceeded {
		return execResult{
			Stderr:   "command timeout (120s)",
			ExitCode: 124,
			CWD:      defaultCWD(),
		}
	}
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			out, outTrunc := trimOutput(stdoutText, maxOutputBytes)
			errOut, errTrunc := trimOutput(stderrText, maxOutputBytes)
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

	out, outTrunc := trimOutput(stdoutText, maxOutputBytes)
	errOut, errTrunc := trimOutput(stderrText, maxOutputBytes)
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

func runHiddenCommand(cmd *exec.Cmd) (stdoutText, stderrText string, err error) {
	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		return "", "", err
	}
	stderrPipe, err := cmd.StderrPipe()
	if err != nil {
		return "", "", err
	}
	if err := cmd.Start(); err != nil {
		return "", "", err
	}

	readLimit := int64(maxOutputBytes + 8192)
	var stdoutBuf, stderrBuf bytes.Buffer
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		_, _ = io.Copy(&stdoutBuf, io.LimitReader(stdoutPipe, readLimit))
	}()
	go func() {
		defer wg.Done()
		_, _ = io.Copy(&stderrBuf, io.LimitReader(stderrPipe, readLimit))
	}()
	wg.Wait()
	err = cmd.Wait()
	return decodeConsoleBytes(stdoutBuf.Bytes()), decodeConsoleBytes(stderrBuf.Bytes()), err
}
