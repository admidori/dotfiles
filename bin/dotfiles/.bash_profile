export PATH=~/.npm-global/bin:$PATH
eval "$(ssh-agent -s)"

ssh-add ~/.ssh/github

if [ -z "$SSH_AUTH_SOCK" ]; then
   # Check for a currently running instance of the agent
   RUNNING_AGENT="`ps -ax | grep 'ssh-agent -s' | grep -v grep | wc -l | tr -d '[:space:]'`"
   if [ "$RUNNING_AGENT" = "0" ]; then
        # Launch a new instance of the agent
        ssh-agent -s &> $HOME/.ssh/ssh-agent
   fi
   eval `cat $HOME/.ssh/ssh-agent`
fi

test -r ~/.bashrc && . ~/.bashrc
export PATH=$PATH:/usr/local/go/bin
