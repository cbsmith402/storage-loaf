#!/bin/bash

# ODroid H4 fan control script
#
# updated version that handles different models  dynamically
#
# v2.1 30-8-2022 ( initial test version )
# v2.2 31-8-2022 ( abstracted hwmon paths and core/drive counts - should now handle any intel cpu and number of drives )


# depends on:
#
# lm_sensors (to query system sensors)
#
# smartmontools + hddtemp (to query hdd temp sensors)
#
# custom it87 kmod to read/set fan speeds
#    needs to be compiled from source ( https://github.com/a1wong/it87 ) as the debian supplied
#    it87 doesn't support the IT8625E used in the asustor



# uses sqr(temp above threshold)+base_pwm for hdd response curve
# uses sqr(temp above threshold/2)+base_pwm for sys response curve
#
# this gives a slow initial ramp up and a rapid final ramp up across the desired temp range (hdd range 35-50 celsius sys range 50-75 celsius )



#
# global variables to tune behaviour
#

# debug output level : 0 = disabled 1 = minimal 2 = verbose 3 = extremely verbose
debug=0

# enable email fan change alets
mailalerts=0

# address we send email alerts to
mail_address=root@locahost
# hostname we use to identify ourselves in email alerts
mail_hostname=AS5202T.home
if [ $debug -gt 1 ]; then
   echo "STARTUP: mail_address=" $mail_address " mail_hostname=" $mail_hostname
fi

# how often we check temps / set speed ( in seconds )
frequency=10

# ratio of how often we update system sensors vs hdd sensors
# sampling the sys sensors is lightweight, wheras querying the hdd sensors via SMART disrupts disk i/o - and hdd temp doesn't change that fast
ratio_sys_to_hdd=12

# the hdd temperature above which we start to increase fan speed
hdd_threshold=30

# the system temperatures above which we start to increase fan speed
sys_threshold=42

# minimum pwm value we ever want to set the fan to
min_pwm=96


#
# determine the /sys/class/hwmon mappings
#

# which /sys/class/hwmon symlink points to the it87 ( fan speed )
hwmon_it87="/sys/class/hwmon/"`ls -lQ /sys/class/hwmon | grep -i it87 | cut -d "\"" -f 2`
if [ $debug -gt 1 ]; then
   echo "STARTUP: hwmon_it87="  $hwmon_it87
fi

# which /sys/class/hwmon symlink points to the intel coretemp sensors
hwmon_coretemp="/sys/class/hwmon/"`ls -lQ /sys/class/hwmon | grep -i coretemp | cut -d "\"" -f 2`
if [ $debug -gt 1 ]; then
   echo "STARUP: hwmon_coretemp=" $hwmon_coretemp
fi

# which /sys/class/hwmon symlink points to the acpi sensors ( board temperature sensor )
hwmon_acpi="/sys/class/hwmon/"`ls -lQ /sys/class/hwmon | grep -i thermal_zone0 | cut -d "\"" -f 2`
if [ $debug -gt 1 ]; then
   echo "STARTUP: hwmon_acpi=" $hwmon_acpi
fi




# set fan speed to desired_pwm
function set_fan_speed() {

    # with the it87 module loaded fan speed is readable via /sys/class/hwmon/hwmonX - the fan speed is on pwm2
    
    echo $desired_pwm >$hwmon_it87/pwm2

}



# query fan speed and set the global fan_rpm
function get_fan_speed() {

    fan_rpm=`cat $hwmon_it87/fan2_input`

}


# query all drive temperatures and set the global hdd_temp to the highest
function get_hdd_temp() {

    # find the highest temperature on all drives
    hdd_temp=`grep -l "drivetemp" /sys/class/hwmon/hwmon*/name | while read f;        
        do echo $((\`cat ${f%/*}/temp1_input\`/1000)); 
    done | sort -rn | head -1`

    if [ $debug -gt 1 ]; then
       echo "GET_HDD_TEMP: hdd_temp= " $hdd_temp
    fi

}




# query system temperatures and set the global sys_temp with the highest
function get_sys_temp() {

    # read the system board temp sensor via acpi
    local acpi_temp=`cat $hwmon_acpi/temp1_input`
    acpi_temp=$(expr $acpi_temp / 1000)

    # read all the temps available via coretemp ( pkg + core1..N ) and return the highest
    local cpu_temp=`cat $hwmon_coretemp/temp?_input | sort -nr | head -1`
    cpu_temp=$(expr $cpu_temp / 1000)

    # choose the greatest of the core and system temps
    sys_temp=$(( $acpi_temp > $cpu_temp ? $acpi_temp : $cpu_temp ))

    if [[ $debug -gt 1 ]] ; then
       echo "GET_SYS_TEMP: acpi temp=" $acpi_temp " cpu_temp=" $cpu_temp " sys_temp=" $sys_temp
    fi

}




# map the current hdd_temp to a desired pwm value
#
# we use base_pwm_value+sqr(hdd_temp-hdd_threshold) to get a nice curve
#
function map_hdd_temp() {
     if [[ $hdd_temp -le $hdd_threshold ]] ; then

          if [[ $debug -gt 1 ]]; then
             echo "MAP_HDD_TEMP: hdd temp=" $hdd_temp " and is under threshold"
          fi

          hdd_desired_pwm=$min_pwm

     else

          if [[ $debug -gt 1 ]] ; then
             echo "MAP_HDD_TEMP: hdd temp=" $hdd_temp " and is over threshold"
          fi

          # get the difference above threshold
          let hdd_desired_pwm=$hdd_temp-$hdd_threshold
          # square it
          let hdd_desired_pwm=$hdd_desired_pwm*$hdd_desired_pwm
          # add it to the base_pwm value
          let hdd_desired_pwm=$min_pwm+$hdd_desired_pwm

     fi

     if [[ $hdd_desired_pwm -gt 255 ]] ; then
          # over max - truncate to max
          hdd_desired_pwm=255
     fi

     if [[ $debug -gt 1 ]] ; then
        echo "MAP_HDD_TEMP: hdd_desired_pwm=" $hdd_desired_pwm
     fi
}




# map the current sys_temp to a desired pwm value
#
# we use base_pwm_value+sqr((hdd_temp-hdd_threshold)/2) to get a nice curve
#
function map_sys_temp() {
     if [[ $sys_temp -le $sys_threshold ]] ; then

          if [[ $debug -gt 1 ]] ; then
             echo "MAP_SYS_TEMP: sys_temp=" $sys_temp " and is under threshold"
          fi

          sys_desired_pwm=$min_pwm

     else

          if [[ $debug -gt 1 ]] ; then
             echo "MAP_SYS_TEMP: sys_temp=" $sys_temp " and is over threshold"
          fi

          # get the difference above threshold
          let sys_desired_pwm=$sys_temp-$sys_threshold
          # halve the difference
          let sys_desired_pwm=$sys_desired_pwm/2
          # then square it
          let sys_desired_pwm=$sys_desired_pwm*$sys_desired_pwm
          # add it to the base pwm value
          let sys_desired_pwm=$min_pwm+$sys_desired_pwm

     fi

     if [[ $sys_desired_pwm -gt 255 ]] ; then
          # over max - truncate to max
          sys_desired_pwm=255
     fi

     if [[ $debug -gt 1 ]] ; then
        echo "MAP_SYS_TEMP: sys_desired_pwm=" $sys_desired_pwm
     fi
}




# determine desired zone based on current temp
function get_desired_pwm() {

    map_sys_temp
    map_hdd_temp

    if [[ $hdd_desired_pwm -gt $sys_desired_pwm ]] ; then
         desired_pwm=$hdd_desired_pwm
         if [[ $debug -gt 2 ]] ; then
            echo "GET_DESIRED_PWM: choosing hdd_pwm value - desired_pwm=" $desired_pwm " hdd_desired_pwm=" $hdd_desired_pwm " sys_desired_pwm=" $sys_desired_pwm
         fi
    else
         desired_pwm=$sys_desired_pwm
         if [[ $debug -gt 2 ]] ; then
            echo "GET_DESIRED_PWM:  choosing sys_pwm value - desired_pwm=" $desired_pwm " hdd_desired_pwm=" $hdd_desired_pwm " sys_desired_pwm=" $sys_desired_pwm
         fi
    fi
}

## MAIN #################################################################################

# get initial temperatures

get_sys_temp
get_hdd_temp
get_fan_speed

last_sys_temp=$sys_temp
last_hdd_temp=$hdd_temp

# we use the variables 'last_pwm' 'last_sys_temp' and 'last_hdd_temp' to track what the pwm/temps values were last time
# thru the loop - so we only change the fan speeds when there's a state change  as opposed to every iteration

# get initial pwm value

get_desired_pwm

last_pwm=$desired_pwm

# set initial fan speed

if [[ $debug -gt 1 ]] ; then
   echo "MAIN: initial fan pwm=" $desired_pwm
fi

set_fan_speed

# now loop forever monitoring and reacting

cycles=$ratio_sys_to_hdd

while true; do

    # update sensor readings

    get_fan_speed

    get_sys_temp

    if [[ $cycles -eq 1 ]] ; then

       if [[ $debug -gt 1 ]] ; then
          echo "MAIN: sampling hdd sensor"
       fi

       get_hdd_temp
       cycles=$ratio_sys_to_hdd

    else

       if [[ $debug -gt 1 ]] ; then
          echo "MAIN: skipping hdd sensor update"
       fi

       let cycles=$cycles-1

    fi

    # update target pwm value based on readings

    get_desired_pwm

    if [[ $debug -gt 1 ]] ; then
         echo "MAIN: desired_pwm=" $desired_pwm " last_pwm=" $last_pwm
         echo "MAIN: sys_temp=" $sys_temp " last_sys_temp=" $last_sys_temp
         echo "MAIN: hdd_temp=" $hdd_temp " last_hdd_temp=" $last_hdd_temp
         echo "MAIN: fan_rpm=" $fan_rpm
    fi

    if [[ $desired_pwm -gt $last_pwm ]] ; then
       # fan speed increase desired - react immediately

       if [[ $debug -ge 1 ]] ; then
          echo "!!!! fan speed INCREASE : hdd_temp " $hdd_temp " sys_temp " $sys_temp " fan_rpm " $fan_rpm " - changing fan speed to " $desired_pwm
       fi

       if [[ $mailalerts -ge 1 ]] ; then
          echo "!!!! fan speed INCREASE : hdd_temp " $hdd_temp " sys_temp " $sys_temp " fan_rpm " $fan_rpm " - changing fan speed to" $desired_pwm | mail $mail_address -s "$mail_name - temperature alert"
       fi

       # set the fan speed

       set_fan_speed

       # update state tracking variables ONLY when there's a change in the target fan speed

       last_pwm=$desired_pwm
       last_sys_temp=$sys_temp
       last_hdd_temp=$hdd_temp
    fi

    if [[ $desired_pwm -lt $last_pwm ]] ; then
       # fan speed decrease desired

       # calculate deltas from last reading for each sensor

       let hdd_delta=$last_hdd_temp-$hdd_temp
       let sys_delta=$last_sys_temp-$sys_temp

       if [[ $debug -gt 1 ]] ; then
          echo "MAIN: current sys_delta=" $sys_delta " current hdd_delta=" $hdd_delta
       fi

       # we need to apply 2 degrees of hysteresis on hdd_temp and 4 degrees on sys_temp to prevent fan speed hunting

       if [[ $hdd_delta -gt 2 ]] || [[ $sys_delta -gt 4 ]] ; then

          # we've got sufficient downward temp delta - actually change the fan speed

          if [[ $debug -ge 1 ]] ; then
             echo "!!!! fan speed DECREASE : hdd_temp " $hdd_temp " sys_temp " $sys_temp " fan_rpm " $fan_rpm " - changing fan speed to " $desired_pwm
          fi
          if [[ $mailalerts -ge 1 ]] ; then
             echo "!!!! fan speed DECREASE : hdd_temp " $hdd_temp " sys_temp " $sys_temp " fan_rpm " $fan_rpm " - changing fan speed to" $desired_pwm | mail $mail_address -s "$mail_name - temperature alert"
          fi

          # set the fan speed

          set_fan_speed

          # update state tracking variables ONLY when there's a change in the target fan speed

          last_pwm=$desired_pwm
          last_sys_temp=$sys_temp
          last_hdd_temp=$hdd_temp

       else

          # not enough downward delta to trigger an actual change yet

          if [[ $debug -ge 1 ]] ; then
             echo "!!!! fan speed DECREASE : hdd_temp " $hdd_temp " sys_temp " $sys_temp " - but not enough delta (" $hdd_delta " " $sys_delta ") yet!"
          fi
       fi
    fi

    if [[ $debug -ge 1 ]] ; then
           echo "MAIN: sleeping for " $frequency " seconds"
    fi
    sleep $frequency

done
