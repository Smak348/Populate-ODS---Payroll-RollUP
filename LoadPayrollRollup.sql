USE [ODS]
GO
/****** Object:  StoredProcedure [dbo].[LoadPayrollRollup]    Script Date: 3/24/2023 7:46:04 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
Description: Load payroll data into LoadPayrollRollup from NXT and Kronos
Example Execute:
	EXEC dbo.LoadPayrollRollup
=============================================================================================================================
Date		Author			Notes
----------	-----------		-------------------------------------------------------------------------------------------------
07/21/2022	Adam Dalsky		Initial Create
=============================================================================================================================
*/

ALTER   PROCEDURE [dbo].[LoadPayrollRollup]
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @now DATETIME = getDate();

	DECLARE @StartDate DATE = (SELECT MAX([Date]) FROM dbo.PayrollRollup);
	DECLARE @EndDate DATE = DATEADD(DAY, -1, getDate());
	DECLARE @AvgRate DECIMAL(8,2) = (SELECT AVG(PayRate) FROM WorkForceManagement.nxt.PayRate WHERE IsActive = 1);

	INSERT INTO  dbo.PayrollRollup (StoreNumber, [Date])
	--	Open and pending closed stores
	SELECT s.Store_Number,
		   c.[Date]
	  FROM Common.dbo.StoreAlignment AS s
	 CROSS JOIN DataMart.dim.Calendar AS c
	 WHERE s.[Status] IN ('Active', 'Pending Closed')
	   AND c.[Date] BETWEEN @StartDate AND @EndDate
	   AND NOT EXISTS
	     (
           SELECT 1
	         FROM dbo.PayrollRollup
	        WHERE [Date] = c.[Date]
	     )

	 UNION
	--	Stores closed on or during our bounding dates
	SELECT s.Store_Number,
		   c.[Date]
	  FROM Common.dbo.StoreAlignment AS s
	 CROSS JOIN DataMart.dim.Calendar AS c
	 WHERE s.[Status] = 'Closed'
	   AND CAST(s.StrClose AS [Date]) BETWEEN @StartDate AND @EndDate
	   AND c.[Date] BETWEEN @StartDate AND @EndDate
	   AND NOT EXISTS
	     (
           SELECT 1
	         FROM dbo.PayrollRollup
	        WHERE [Date] = c.[Date]
	     )
	 ORDER BY [Date],
		   Store_Number;

	DECLARE @TodaysRunDate DATETIME = (SELECT MAX(SystemCreateDate) FROM dbo.PayrollRollup WHERE CAST(SystemCreateDate AS DATE) = CAST(getDate() AS DATE));

	--	Full Time Salary
	WITH CTE_HourlyWages
	  AS
	   (
	SELECT a.Associate_Home_Store_Nbr AS StoreNumber,
			CASE
				WHEN (a.Associate_Status = 'A') THEN CONVERT(NUMERIC(4,2), CONVERT(VARCHAR(15), DECRYPTBYPASSPHRASE('f%7R6k3y#@oP9_', o.hourly_wage))) * 8.0
				ELSE (CONVERT(NUMERIC(4,2), CONVERT(VARCHAR(15), DECRYPTBYPASSPHRASE('f%7R6k3y#@oP9_', o.hourly_wage))) * 8.0) / 2.0
			END AS DollarAmountEarned,
           8 AS [Hours],
		   ROW_NUMBER() OVER (PARTITION BY o.Employee_Id ORDER BY o.Updated_Date DESC) AS RN
	  FROM WorkForceManagement.dbo.ADP_Operations AS o
	 INNER JOIN WorkForceManagement.dbo.ADP_Associate AS a
		ON o.Employee_Id = a.Associate_Id
	   AND TRY_CAST(RIGHT(o.Department_Desc, LEN(o.Department_Desc) - CHARINDEX(' ', o.Department_Desc)) AS INT) = a.Associate_Home_Store_Nbr
	 WHERE a.Associate_Status IN ('A', 'L', 'S')
	   AND o.Salary_Type = 'S'
	   )

	UPDATE p
	   SET p.FullTimeSalaryDollars = w.Salary,
	       p.FullTimeSalaryHours = w.[Hours]
	  FROM dbo.PayrollRollup AS p
	 INNER JOIN
		 (
		   SELECT StoreNumber,
				  SUM(DollarAmountEarned) AS Salary,
	              SUM([Hours]) AS [Hours]
			 FROM CTE_HourlyWages
			WHERE RN = 1
			GROUP BY StoreNumber
		 ) AS w
		ON p.StoreNumber = w.StoreNumber
	 INNER JOIN DataMart.dim.Calendar AS c
	    ON p.[Date] = c.[Date]
	   AND c.[DayOfWeek] NOT IN (1,7)
	   AND p.SystemCreateDate = @TodaysRunDate;

	--	Full Time Hourly
	UPDATE p
	   SET p.FullTimeHourlyDollars = t.FullTimeDollars,
	       p.FullTimeHourlyHours = ISNULL(t.FullTimeHours, 0)
	  FROM dbo.PayrollRollup AS p
	 INNER JOIN
		 (
		   SELECT b.StoreNumber,
	              b.ApplyDate,
				  CAST(SUM(b.TotalFullTimeDollars) AS DECIMAL(8,2)) AS FullTimeDollars,
				  CAST(SUM(b.TotalFullTimeHours) AS DECIMAL(8,2)) AS FullTimeHours
			 FROM
				(
				  SELECT p.StoreNumber,
	                     p.ApplyDate,
						 CASE WHEN a.Associate_Job_Type = 'F' THEN SUM(p.DollarAmountEarned) ELSE 0 END AS TotalFullTimeDollars,
	                     CASE WHEN a.Associate_Job_Type = 'F' THEN SUM(p.WorkMinutes) / 60 ELSE 0 END AS TotalFullTimeHours
					FROM WorkForceManagement.kronos.Payroll AS p
				   INNER JOIN WorkForceManagement.dbo.ADP_Associate AS a
					  ON p.EmployeeID = a.Associate_Id
	                 AND p.StoreNumber = a.Associate_Home_Store_Nbr
				   WHERE a.Associate_Reg_Temp = 'R'
					 AND p.PayCodeName NOT IN ('CA Daily Overtime', 'Double Time', 'Overtime', 'Overtime - Sunday') -- Overtime bucket
				   GROUP BY p.StoreNumber,
	                     p.ApplyDate,
						 a.Associate_Job_Type
				) AS b
			GROUP BY b.StoreNumber,
	              b.ApplyDate
		 ) AS t
		ON p.StoreNumber = t.StoreNumber
	   AND p.[Date] = t.ApplyDate
	   AND p.SystemCreateDate = @TodaysRunDate;

	--	Part Time Hourly
	UPDATE p
	   SET p.PartTimeHourlyDollars = t.PartTimeDollars,
	       p.PartTimeHourlyHours = t.PartTimeHours
	  FROM dbo.PayrollRollup AS p
	 INNER JOIN
		 (
		   SELECT b.StoreNumber,
	              b.ApplyDate,
				  CAST(SUM(b.TotalFullTimeDollars) AS DECIMAL(8,2)) AS PartTimeDollars,
				  CAST(SUM(b.TotalFullTimeHours) AS DECIMAL(8,2)) AS PartTimeHours
			 FROM
				(
				  SELECT p.StoreNumber,
	                     p.ApplyDate,
						 CASE WHEN a.Associate_Job_Type = 'P' THEN SUM(p.DollarAmountEarned) ELSE 0 END AS TotalFullTimeDollars,
						 CASE WHEN a.Associate_Job_Type = 'P' THEN SUM(p.WorkMinutes) / 60 ELSE 0 END AS TotalFullTimeHours
					FROM WorkForceManagement.kronos.Payroll AS p
				   INNER JOIN WorkForceManagement.dbo.ADP_Associate AS a
					  ON p.EmployeeID = a.Associate_Id
	                 AND p.StoreNumber = a.Associate_Home_Store_Nbr
				   WHERE a.Associate_Reg_Temp = 'R'
					 AND p.PayCodeName NOT IN ('CA Daily Overtime', 'Double Time', 'Overtime', 'Overtime - Sunday') -- Overtime bucket
				   GROUP BY p.StoreNumber,
	                     p.ApplyDate,
						 a.Associate_Job_Type
				) AS b
			GROUP BY b.StoreNumber,
	              b.ApplyDate
		 ) AS t
		ON p.StoreNumber = t.StoreNumber
	   AND p.[Date] = t.ApplyDate
	   AND p.SystemCreateDate = @TodaysRunDate;

	--	Temp
	UPDATE p
	   SET p.TempDollars = t.TempDollars,
	       p.TempHours = t.TempHours
	  FROM dbo.PayrollRollup AS p
	 INNER JOIN
		 (
		   SELECT b.StoreNumber,
	              b.ApplyDate,
				  CAST(SUM(b.TotalFullTimeDollars) AS DECIMAL(8,2)) AS TempDollars,
				  CAST(SUM(b.TotalFullTimeHours) AS DECIMAL(8,2)) AS TempHours
			 FROM
				(
				  SELECT p.StoreNumber,
	                     p.ApplyDate,
						 SUM(p.DollarAmountEarned) AS TotalFullTimeDollars,
						 SUM(p.WorkMinutes) / 60 AS TotalFullTimeHours
					FROM WorkForceManagement.kronos.Payroll AS p
				   INNER JOIN WorkForceManagement.dbo.ADP_Associate AS a
					  ON p.EmployeeID = a.Associate_Id
	                 AND p.StoreNumber = a.Associate_Home_Store_Nbr
				   WHERE a.Associate_Reg_Temp = 'T'
					 AND p.PayCodeName NOT IN ('CA Daily Overtime', 'Double Time', 'Overtime', 'Overtime - Sunday') -- Overtime bucket
				   GROUP BY p.StoreNumber,
	                     p.ApplyDate
				) AS b
			GROUP BY b.StoreNumber,
	              b.ApplyDate
		 ) AS t
		ON p.StoreNumber = t.StoreNumber
	   AND p.[Date] = t.ApplyDate
	   AND p.SystemCreateDate = @TodaysRunDate;

	--	Temps - Add in NXTThing
	UPDATE p
	   SET p.TempDollars = p.TempDollars + t.RegularDollars,
	       p.TempHours = p.TempHours + t.RegularHours
	  FROM dbo.PayrollRollup AS p
	 INNER JOIN
		 (
		   SELECT p.StoreNumber,
	              p.TimecardPayDate,
				  SUM(p.RegularHours * ISNULL(r.PayRate, @AvgRate)) AS RegularDollars,
				  SUM(p.RegularHours) AS RegularHours
			 FROM WorkForceManagement.nxt.Payroll AS p
			 LEFT JOIN WorkForceManagement.nxt.PayRate AS r
			   ON p.StoreNumber = r.StoreNumber
			  AND r.IsActive = 1
			GROUP BY p.StoreNumber,
	              p.TimecardPayDate
		 ) AS t
		ON p.StoreNumber = t.StoreNumber
	   AND p.[Date] = t.TimecardPayDate
	   AND p.SystemCreateDate = @TodaysRunDate;

	--	Overtime - Include Kronos overtime paycodes and NXT overtime
	--	Kronos Part Time Hourly
	--	Full Time, Part Time, and Temps Hourly
	UPDATE p
	   SET p.OvertimeDollars = t.OvertimeDollars,
	       p.OvertimeHours = t.OvertimeHours
	  FROM dbo.PayrollRollup AS p
	 INNER JOIN
		 (
		   SELECT b.StoreNumber,
	              b.ApplyDate,
				  CAST(SUM(b.OvertimeDollars) AS DECIMAL(8,2)) AS OvertimeDollars,
				  CAST(SUM(b.OvertimeHours) AS DECIMAL(8,2)) AS OvertimeHours
			 FROM
				(
				  SELECT p.StoreNumber,
	                     p.ApplyDate,
						 SUM(p.DollarAmountEarned) AS OvertimeDollars,
						 SUM(p.WorkMinutes) / 60 AS OvertimeHours
					FROM WorkForceManagement.kronos.Payroll AS p
				   INNER JOIN WorkForceManagement.dbo.ADP_Associate AS a
					  ON p.EmployeeID = a.Associate_Id
	                 AND p.StoreNumber = a.Associate_Home_Store_Nbr
				   WHERE p.PayCodeName IN ('CA Daily Overtime', 'Double Time', 'Overtime', 'Overtime - Sunday') -- Overtime bucket
				   GROUP BY p.StoreNumber,
	                     p.ApplyDate,
						 a.Associate_Job_Type
				) AS b
			GROUP BY b.StoreNumber,
	              b.ApplyDate
		 ) AS t
		ON p.StoreNumber = t.StoreNumber
	   AND p.[Date] = t.ApplyDate
	   AND p.SystemCreateDate = @TodaysRunDate;

	--	Overtime - Include Kronos overtime paycodes and NXT overtime
	--	NXTThing
	UPDATE p
	   SET p.OvertimeDollars = p.OvertimeDollars + t.OvertimeDollars,
	       p.OvertimeHours = p.OvertimeHours + t.OvertimeHours
	  FROM dbo.PayrollRollup AS p
	 INNER JOIN
		 (
		   SELECT n.StoreNumber,
	              n.TimecardPayDate,
				  SUM(n.OvertimeHours * (ISNULL(r.PayRate, @AvgRate) * 1.5)) AS OvertimeDollars,
				  SUM(n.OvertimeHours) AS OvertimeHours
			 FROM WorkForceManagement.nxt.Payroll AS n
			 LEFT JOIN WorkForceManagement.nxt.PayRate AS r
			   ON n.StoreNumber = r.StoreNumber
			  AND r.IsActive = 1
			GROUP BY n.StoreNumber,
	              n.TimecardPayDate
		 ) AS t
		ON p.StoreNumber = t.StoreNumber
	   AND p.[Date] = t.TimecardPayDate
	   AND p.SystemCreateDate = @TodaysRunDate;

	--	Total Payroll
	UPDATE dbo.PayrollRollup
	   SET TotalPayrollDollars = FullTimeSalaryDollars + FullTimeHourlyDollars + PartTimeHourlyDollars + TempDollars + OvertimeDollars,
	       TotalPayrollHours = FullTimeSalaryHours + FullTimeHourlyHours + PartTimeHourlyHours + TempHours + OvertimeHours
	 WHERE SystemCreateDate = @TodaysRunDate;

	--	Clean up
	DELETE FROM dbo.PayrollRollup
	 WHERE TotalPayrollDollars = 0;
END
